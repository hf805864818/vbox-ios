import Foundation
import Combine
import CryptoKit

/// 用于 CloudDriveManager 向播放器 Debug Overlay 广播日志
extension Notification.Name {
    static let cloudDriveLog = Notification.Name("cloudDriveLog")
}

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

    /// 广播日志到播放器 Debug Overlay（替代 print，便于用户直接看到关键流程）
    private func log(_ message: String) {
        print(message)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .cloudDriveLog, object: message)
        }
    }
    private static let baiduPCSUserAgent = "Mozilla/5.0 (Linux; Android 12; HD1900 Build/SKQ1.211113.001) AppleWebKit/537.36 (KHTML, like Gecko)&channel=android_12_HD1900_bdnetdisktv_1025538l&version=1.21.1&network_type=wifi&app_id=250528&size=c1080_u1600"
    // 严格对齐 iBox 百度路链：分享文件先转存到固定目录，再从用户网盘路径取链播放。
    // 注意：百度 API 的真实根路径是 "/"；App 里看到的“我的资源”是 UI 分类名，不应写进 API path。
    // 因此这里请求用 "/vbox"，在百度网盘 UI 里会显示为“我的资源/vbox”。
    private static let baiduIBoxTransferDir = "/vbox"

    enum DriveType: String, CaseIterable {
        case ali = "ali"
        case quark = "quark"
        case baidu = "baidu"
        case one15 = "115"
        case uc = "uc"
        case pan123 = "123pan"
        case pan139 = "139pan"
        case pan189 = "189pan"

        var displayName: String {
            switch self {
            case .ali: return "阿里云盘"
            case .quark: return "夸克网盘"
            case .baidu: return "百度网盘"
            case .one15: return "115网盘"
            case .uc: return "UC网盘"
            case .pan123: return "123云盘"
            case .pan139: return "139云盘"
            case .pan189: return "天翼云盘"
            }
        }

        var tokenLabel: String {
            switch self {
            case .ali: return "Refresh Token"
            case .quark: return "Cookie"
            case .baidu: return "完整 Cookie / BDUSS+STOKEN"
            case .one15: return "完整 Cookie / CID"
            case .uc: return "Cookie"
            case .pan123: return "Cookie / Token"
            case .pan139: return "Cookie / Session"
            case .pan189: return "Cookie / 用户名密码"
            }
        }
    }

    private let session: URLSession
    private let ucSession: URLSession
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
    private let cleanupQueueKey = "cloud_drive_cleanup_queue_v1"
    private let quarkVboxFolderCacheKey = "quark_vbox_folder_cache_v1"
    private let quarkSavedFidCacheKey = "quark_saved_fid_cache_v1"

    private struct CleanupQueueItem: Codable, Hashable {
        let drive: String
        let tokenName: String
        let fileId: String
        let eligibleAt: Date
        let createdAt: Date
    }
    /// 夸克转存后的对象 fid 缓存，用于避免同一资源重复转存
    /// - topLevelFids: sharepage/save 返回的 save_as_top_fids，可能是文件或文件夹
    /// - playbackFileId: 实际用于 v2/play / download_url 的视频文件 fid
    private struct QuarkSavedFidCacheItem: Codable {
        let topLevelFids: [String]
        let playbackFileId: String?
        let fileName: String
        let folderId: String
        let cookieHash: String
        let createdAt: Date
        let expiresAt: Date
    }
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
        let randsk: String?
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

    // 夸克：vbox 目录缓存 & 单飞（避免并发/重复创建导致同名冲突）
    private let quarkVboxCacheLock = NSLock()
    private var quarkVboxFolderCache: [String: String] = [:] // accountKey -> folderId
    private var quarkEnsureFolderTasks: [String: Task<(folderId: String, cookie: String), Error>] = [:]

    @Published private(set) var savedTokens: [DriveToken] = []
    private var cleanupWorkerTask: Task<Void, Never>?

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        
        let ucConfig = URLSessionConfiguration.ephemeral
        ucConfig.timeoutIntervalForRequest = 30
        ucSession = URLSession(configuration: ucConfig)
        
        loadTokens()
        loadQuarkVboxFolderCache()
        startCleanupWorkerIfNeeded()
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

    private func baiduCachedShareContext(for key: String, currentPwd: String?) -> BaiduShareContext? {
        var cache = baiduLoadPersistedShareContextCache()
        guard let context = cache[key] else { return nil }
        // 缓存版本必须按当前分享链接校验，不能只看旧缓存里的 pwd。
        // 老版本缓存可能没有 randsk/bdstoken，但仍会被命中，导致直接跳过 iBox verify，
        // 最终 share/transfer 缺 sekey 或 api/create 缺 bdstoken，返回 errno=2/-6。
        let currentShareNeedsRandsk = !(currentPwd ?? "").isEmpty
        if context.expiresAt > Date(),
           !context.shareid.isEmpty,
           !context.shareUk.isEmpty,
           !context.files.isEmpty,
           !(context.bdstoken ?? "").isEmpty,
           (!currentShareNeedsRandsk || !(context.randsk ?? "").isEmpty) {
            return context
        }
        baiduLog("[Baidu-ShareContext] ⚠️ 丢弃不完整分享上下文缓存：bdstoken=\(!((context.bdstoken ?? "").isEmpty)), randsk=\(!((context.randsk ?? "").isEmpty)), currentPwd=\(currentShareNeedsRandsk)")
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
        randsk: String? = nil,
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
            randsk: randsk,
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

    private func baiduIsPlayableVideoFileName(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        let videoExts = [
            "mp4", "mkv", "mov", "m4v", "avi", "wmv", "flv", "ts", "m2ts", "mts",
            "webm", "mpg", "mpeg", "3gp", "rm", "rmvb", "asf", "f4v", "m3u8"
        ]
        return videoExts.contains { lower.hasSuffix(".\($0)") }
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
        do {
            if let tokens = try SecureCredentialStore.loadTokens() {
                savedTokens = tokens
                return
            }
        } catch {
            print("[CloudDriveManager] Keychain 读取 tokens 失败: \(error)")
        }

        // 从旧版 UserDefaults 迁移一次
        if let data = defaults.data(forKey: tokenKey),
           let tokens = try? JSONDecoder().decode([DriveToken].self, from: data) {
            savedTokens = tokens
            do {
                try SecureCredentialStore.save(tokens: tokens)
                print("[CloudDriveManager] 已从 UserDefaults 迁移 tokens 到 Keychain")
            } catch {
                print("[CloudDriveManager] 迁移 tokens 到 Keychain 失败: \(error)")
            }
            defaults.removeObject(forKey: tokenKey)
        }
    }

    private func saveTokens() {
        do {
            try SecureCredentialStore.save(tokens: savedTokens)
        } catch {
            print("[CloudDriveManager] Keychain 保存 tokens 失败: \(error)")
        }
    }

    private func loadQuarkVboxFolderCache() {
        quarkVboxCacheLock.lock()
        defer { quarkVboxCacheLock.unlock() }
        guard let data = defaults.data(forKey: quarkVboxFolderCacheKey),
              let cache = try? JSONDecoder().decode([String: String].self, from: data) else {
            quarkVboxFolderCache = [:]
            return
        }
        quarkVboxFolderCache = cache
    }

    private func saveQuarkVboxFolderCache() {
        quarkVboxCacheLock.lock()
        let cache = quarkVboxFolderCache
        quarkVboxCacheLock.unlock()
        if let data = try? JSONEncoder().encode(cache) {
            defaults.set(data, forKey: quarkVboxFolderCacheKey)
        }
    }

    private func setQuarkVboxFolderCache(accountKey: String, folderId: String) {
        guard !accountKey.isEmpty, !folderId.isEmpty else { return }
        quarkVboxCacheLock.lock()
        quarkVboxFolderCache[accountKey] = folderId
        quarkVboxCacheLock.unlock()
        saveQuarkVboxFolderCache()
    }

    private func clearQuarkVboxFolderCache(accountKey: String) {
        guard !accountKey.isEmpty else { return }
        quarkVboxCacheLock.lock()
        quarkVboxFolderCache.removeValue(forKey: accountKey)
        quarkEnsureFolderTasks.removeValue(forKey: accountKey)
        quarkVboxCacheLock.unlock()
        saveQuarkVboxFolderCache()
    }

    // MARK: - 夸克转存后 fileId 缓存

    private func quarkSavedFidCacheKey(pwdId: String, sourceFid: String, folderId: String, cookie: String) -> String {
        let cookieHash = String(cookie.hash)
        return "\(pwdId)|\(sourceFid)|\(folderId)|\(cookieHash)"
    }

    private func loadQuarkSavedFidCache() -> [String: QuarkSavedFidCacheItem] {
        guard let data = defaults.data(forKey: quarkSavedFidCacheKey),
              let cache = try? JSONDecoder().decode([String: QuarkSavedFidCacheItem].self, from: data) else {
            return [:]
        }
        return cache
    }

    private func saveQuarkSavedFidCache(_ cache: [String: QuarkSavedFidCacheItem]) {
        var cleaned = cache
        let now = Date()
        cleaned = cleaned.filter { $0.value.expiresAt > now }
        if cleaned.count > 300 {
            cleaned = Dictionary(uniqueKeysWithValues: cleaned.sorted { $0.value.createdAt > $1.value.createdAt }.prefix(300).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(cleaned) {
            defaults.set(data, forKey: quarkSavedFidCacheKey)
        }
    }

    private func quarkCachedSavedTopFids(pwdId: String, sourceFid: String, folderId: String, cookie: String) -> [String]? {
        let key = quarkSavedFidCacheKey(pwdId: pwdId, sourceFid: sourceFid, folderId: folderId, cookie: cookie)
        var cache = loadQuarkSavedFidCache()
        guard let item = cache[key], item.expiresAt > Date() else {
            if cache[key] != nil {
                cache.removeValue(forKey: key)
                saveQuarkSavedFidCache(cache)
            }
            return nil
        }
        self.log("[Quark] ✅ 命中转存 fid 缓存: \(item.topLevelFids)，跳过本次转存")
        return item.topLevelFids
    }

    private func quarkStoreSavedItem(topLevelFids: [String], playbackFileId: String?, fileName: String, folderId: String, cookie: String, pwdId: String, sourceFid: String, ttl: TimeInterval = 5 * 60) {
        guard !topLevelFids.isEmpty, !topLevelFids.allSatisfy({ $0 == "0" }) else { return }
        let key = quarkSavedFidCacheKey(pwdId: pwdId, sourceFid: sourceFid, folderId: folderId, cookie: cookie)
        var cache = loadQuarkSavedFidCache()
        cache[key] = QuarkSavedFidCacheItem(
            topLevelFids: topLevelFids,
            playbackFileId: playbackFileId,
            fileName: fileName,
            folderId: folderId,
            cookieHash: String(cookie.hash),
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(ttl)
        )
        saveQuarkSavedFidCache(cache)
        self.log("[Quark] 💾 已缓存转存对象: topLevelFids=\(topLevelFids), playbackFileId=\(playbackFileId ?? "nil")，有效期 \(Int(ttl/60)) 分钟")
    }

    private func quarkInvalidateSavedFidCache(pwdId: String, sourceFid: String, folderId: String, cookie: String) {
        let key = quarkSavedFidCacheKey(pwdId: pwdId, sourceFid: sourceFid, folderId: folderId, cookie: cookie)
        var cache = loadQuarkSavedFidCache()
        guard cache[key] != nil else { return }
        cache.removeValue(forKey: key)
        saveQuarkSavedFidCache(cache)
        self.log("[Quark] 🗑️ 已清除失效的转存 fid 缓存")
    }

    /// 清理缓存中除当前 key 外的所有历史转存对象，保留当前正在播放的转存文件/文件夹
    private func quarkCleanupPreviousSavedItems(excludingKey currentKey: String, cookie: String) async -> String {
        var currentCookie = cookie
        var cache = loadQuarkSavedFidCache()
        var keysToRemove: [String] = []
        var fidsToDelete: [String] = []
        for (key, item) in cache {
            guard key != currentKey else { continue }
            keysToRemove.append(key)
            fidsToDelete.append(contentsOf: item.topLevelFids)
        }
        guard !fidsToDelete.isEmpty else { return currentCookie }

        let uniqueFids = Array(Set(fidsToDelete)).filter { !$0.isEmpty && $0 != "0" }
        guard !uniqueFids.isEmpty else { return currentCookie }

        self.log("[Quark] 🧹 新转存完成，清理 \(uniqueFids.count) 个历史转存对象：\(uniqueFids)")
        currentCookie = await quarkDeleteFiles(fileIds: uniqueFids, cookie: currentCookie)

        for key in keysToRemove {
            cache.removeValue(forKey: key)
        }
        saveQuarkSavedFidCache(cache)
        self.log("[Quark] 🧹 已清理 \(keysToRemove.count) 条历史转存缓存")
        return currentCookie
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
        guard !fileIds.isEmpty else { return }
        let tokenName = resolveTokenName(drive: drive, tokenValue: token)
        enqueueCleanup(drive: drive, tokenName: tokenName, fileIds: fileIds, delay: delay)
        startCleanupWorkerIfNeeded()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.flushCleanupQueue()
        }
    }

    private func cleanupFiles(drive: DriveType, fileIds: [String], token: String) async {
        self.log("[CloudDrive] 清理 \(drive.rawValue) 转存文件: \(fileIds.count) 个")
        switch drive {
        case .quark: await quarkDeleteFiles(fileIds: fileIds, cookie: token)
        case .baidu: await baiduDeleteFiles(fileIds: fileIds, bduss: token)
        case .uc: await ucDeleteFiles(fileIds: fileIds, cookie: token)
        default: break
        }
    }

    private func resolveTokenName(drive: DriveType, tokenValue: String) -> String {
        // 先尝试完全匹配（常规手动 Token 路径）
        if let exact = savedTokens.first(where: { $0.type == drive.rawValue && $0.value == tokenValue }) {
            return exact.name
        }
        // 对于百度，pureAccountCookie 是合并/过滤后的合成值，与 savedTokens 中的原始 Cookie
        // 不完全相等，但 BDUSS 相同。通过 BDUSS 值匹配来找到对应的 Token。
        if drive == .baidu, let bduss = baiduCookieValue(tokenValue, named: "BDUSS") {
            return savedTokens.first(where: { token in
                guard token.type == drive.rawValue else { return false }
                return baiduCookieValue(token.value, named: "BDUSS") == bduss
            })?.name ?? ""
        }
        return ""
    }

    private func tokenValue(for drive: DriveType, tokenName: String) -> String? {
        if !tokenName.isEmpty,
           let found = tokens(for: drive).first(where: { $0.name == tokenName }) {
            return found.value
        }
        // 兜底：百度优先返回 Account Web Token（含 BDUSS+STOKEN），
        // 避免返回 PCS Token（仅用于下载直链，无法调用 filemanager 删除 API）
        let candidates = tokens(for: drive)
        if drive == .baidu {
            if let account = candidates.first(where: { isBaiduAccountWebToken($0) }) {
                return account.value
            }
        }
        return candidates.first?.value
    }

    private func loadCleanupQueue() -> [CleanupQueueItem] {
        guard let data = defaults.data(forKey: cleanupQueueKey),
              let items = try? JSONDecoder().decode([CleanupQueueItem].self, from: data) else {
            return []
        }
        return items
    }

    private func saveCleanupQueue(_ items: [CleanupQueueItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: cleanupQueueKey)
    }

    private func enqueueCleanup(drive: DriveType, tokenName: String, fileIds: [String], delay: TimeInterval) {
        let now = Date()
        let eligibleAt = now.addingTimeInterval(delay)
        var queue = loadCleanupQueue()
        var existing = Set(queue.map { ($0.drive, $0.tokenName, $0.fileId) }.map { "\($0.0)|\($0.1)|\($0.2)" })

        for fid in fileIds where !fid.isEmpty {
            let key = "\(drive.rawValue)|\(tokenName)|\(fid)"
            if existing.contains(key) { continue }
            existing.insert(key)
            queue.append(
                CleanupQueueItem(
                    drive: drive.rawValue,
                    tokenName: tokenName,
                    fileId: fid,
                    eligibleAt: eligibleAt,
                    createdAt: now
                )
            )
        }

        // 防止队列无限增长：保留最新 300 条
        if queue.count > 300 {
            queue.sort { $0.createdAt > $1.createdAt }
            queue = Array(queue.prefix(300))
        }
        saveCleanupQueue(queue)
    }

    private func startCleanupWorkerIfNeeded() {
        guard cleanupWorkerTask == nil else { return }
        cleanupWorkerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.flushCleanupQueue()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    private func flushCleanupQueue() async {
        var queue = loadCleanupQueue()
        guard !queue.isEmpty else { return }
        let now = Date()

        let due = queue.filter { $0.eligibleAt <= now }
        guard !due.isEmpty else { return }

        // 按 drive + tokenName 分组批量删除，减少 API 调用
        var groups: [String: [String]] = [:]
        for item in due {
            let k = "\(item.drive)|\(item.tokenName)"
            groups[k, default: []].append(item.fileId)
        }

        for (key, fids) in groups {
            let parts = key.components(separatedBy: "|")
            guard parts.count >= 2 else { continue }
            let driveRaw = parts[0]
            let tokenName = parts[1]
            guard let drive = DriveType(rawValue: driveRaw) else { continue }
            guard let tokenValue = tokenValue(for: drive, tokenName: tokenName), !tokenValue.isEmpty else {
                continue
            }
            // 去重并控制每批最大数量
            let unique = Array(Set(fids)).filter { !$0.isEmpty }
            if unique.isEmpty { continue }
            let batches = stride(from: 0, to: unique.count, by: 100).map { Array(unique[$0..<min($0 + 100, unique.count)]) }
            for batch in batches {
                await cleanupFiles(drive: drive, fileIds: batch, token: tokenValue)
            }
        }

        // 删除已到期的任务（默认认为提交删除即可；失败会在下次播放/触发兜底清理时再覆盖）
        let dueSet = Set(due)
        queue.removeAll { dueSet.contains($0) }
        saveCleanupQueue(queue)
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
        // 治理隐患 1：先按形式合法过滤；同时把「与授权中心 credential.cookie 不一致的旧账号 cookie」也清掉。
        // 这样能避免历史扫码留下的、形式合法但已过期的 BDUSS+STOKEN 仍被 baiduTokenPair 当作候选。
        let authoritativeCookie = CloudDriveAuthManager.shared.credential(for: .baidu)?.cookie
        savedTokens.removeAll { token in
            guard token.type == DriveType.baidu.rawValue else { return false }
            if !isBaiduPCSToken(token) && !isBaiduAccountWebToken(token) {
                return true
            }
            // 仅对「账号 cookie」做唯一性约束；PCS cookie 不参与 BDUSS/STOKEN 比对。
            if isBaiduAccountWebToken(token),
               let authoritativeCookie,
               isBaiduAccountWebCookie(authoritativeCookie),
               token.value != authoritativeCookie {
                return true
            }
            return false
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

        let preferredWeb: DriveToken?
        if let credential = CloudDriveAuthManager.shared.credential(for: .baidu),
           let cookie = credential.cookie,
           isBaiduAccountWebCookie(cookie) {
            // 百度主路链必须优先使用授权中心最新扫码 Cookie。
            // 旧 legacy Cookie 可能已过期，若排在前面会导致 api/gettemplatevariable/api/create 返回 errno=-6/-9。
            let name = credential.userName?.isEmpty == false ? credential.userName! : "授权中心"
            preferredWeb = DriveToken(type: DriveType.baidu.rawValue, name: name, value: cookie)
        } else {
            preferredWeb = nil
        }

        guard let web = preferredWeb ?? list.first(where: { isBaiduAccountWebToken($0) }) else {
            baiduLog("[Baidu-Token] ❌ 缺少百度 Web Cookie：需要同时包含 BDUSS 和 STOKEN，不能用 PCS Cookie 替代")
            return nil
        }
        // 治理隐患 2：PCS Cookie 仅采用授权中心 credential.extra 中保存的最新值，
        // 不再回退到 legacy savedTokens，避免历史粘贴/旧扫码留下的过期 PCS 被带入 share/transfer。
        let pcs: DriveToken?
        if let credential = CloudDriveAuthManager.shared.credential(for: .baidu),
           let pcsValue = credential.extra["pcs_cookie"], !pcsValue.isEmpty,
           isBaiduPCSCookie(pcsValue) {
            let pcsName = "授权中心-PCS"
            pcs = DriveToken(type: DriveType.baidu.rawValue, name: pcsName, value: pcsValue)
        } else {
            pcs = nil
        }
        return (web, pcs)
    }

    static func detectDrive(from url: String) -> DriveType? {
        if url.contains("aliyundrive.com") || url.contains("alipan.com") { return .ali }
        if url.contains("pan.quark.cn") { return .quark }
        if url.contains("pan.baidu.com") { return .baidu }
        if url.contains("115.com") || url.contains("115cdn.com") { return .one15 }
        if url.contains("uc.cn") || url.contains("ucloud.cn") { return .uc }
        if url.contains("123pan.com") || url.contains("123cloud.cn") { return .pan123 }
        if url.contains("yun.139.com") || url.contains("139.com") { return .pan139 }
        if url.contains("cloud.189.cn") || url.contains("189.cn") { return .pan189 }
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

        var transcodeURL: String?
        do {
            let playInfo = try await aliGetVideoPreviewPlayInfo(fileId: file.fileId, shareToken: shareToken, token: accessToken)
            let taskList = playInfo.videoPreviewPlayInfo?.liveTranscodingTaskList ?? []
            let qualityOrder = ["QHD", "FHD", "HD", "SD", "LD"]
            transcodeURL = qualityOrder.compactMap { quality in
                taskList.first { ($0.templateId ?? "").uppercased().contains(quality) }?.url
            }.first ?? taskList.first(where: { ($0.url ?? "").isEmpty == false })?.url
            print("[Ali] 转码线路: \(transcodeURL != nil ? "已获取" : "未获取")")
        } catch {
            print("[Ali] ⚠️ 转码线路获取失败，将尝试原画直链: \(error.localizedDescription)")
        }

        var downloadURL: String?
        do {
            downloadURL = try await aliGetDownloadURL(fileId: file.fileId, shareId: shareInfo.shareId, shareToken: shareToken, token: accessToken)
            print("[Ali] 原画直链: \(downloadURL != nil ? "已获取" : "未获取")")
        } catch {
            print("[Ali] ⚠️ 原画直链获取失败: \(error.localizedDescription)")
        }

        let playbackHeaders = aliPlaybackHeaders(accessToken: accessToken, shareToken: shareToken)

        let playURL: String
        let source: String
        if let url = transcodeURL {
            playURL = url
            source = "transcode"
        } else if let url = downloadURL {
            playURL = url
            source = "download_url"
        } else {
            throw DriveError.noPlayURL("阿里: 转码地址和原画直链均获取失败")
        }

        let fallbackURL: String?
        let fallbackSource: String?
        if source == "transcode", let url = downloadURL {
            fallbackURL = url
            fallbackSource = "download_url"
        } else if source == "download_url", let url = transcodeURL {
            fallbackURL = url
            fallbackSource = "transcode"
        } else {
            fallbackURL = nil
            fallbackSource = nil
        }

        print("[Ali] ✅ 主线路 source=\(source), host=\(URL(string: playURL)?.host ?? "unknown")")
        if let fallbackURL, let fallbackSource {
            print("[Ali] ✅ 兜底线路 source=\(fallbackSource), host=\(URL(string: fallbackURL)?.host ?? "unknown")")
        }

        return PlayResult(
            url: playURL,
            headers: playbackHeaders,
            driveType: .ali,
            source: source,
            fallbackURL: fallbackURL,
            fallbackHeaders: fallbackURL == nil ? nil : playbackHeaders,
            fallbackSource: fallbackSource
        )
    }

    private func aliRefreshAccessToken(refreshToken: String) async throws -> AliTokenResponse {
        var request = URLRequest(url: URL(string: "https://api.alipan.com/v2/account/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "client_id": "25dzX3vbRqA4f1D1ma2M"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        // 先检查 code，避免错误响应被 JSONDecoder 误解析
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let code = json["code"] as? String, code != "OK" && code != "ok" && code != "0" {
                let msg = json["message"] as? String ?? code
                throw DriveError.noPlayURL("阿里 token 刷新失败：\(msg)")
            }
            if let code = json["code"] as? Int, code != 0 && code != 200 {
                let msg = json["message"] as? String ?? "code=\(code)"
                throw DriveError.noPlayURL("阿里 token 刷新失败：\(msg)")
            }
        }
        return try JSONDecoder().decode(AliTokenResponse.self, from: data)
    }

    private func aliGetShareToken(shareId: String, sharePwd: String?, token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.alipan.com/v2/share_link/get_share_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["share_id": shareId]
        if let sharePwd, !sharePwd.isEmpty { body["share_pwd"] = sharePwd }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let codeStr = json["code"] as? String
            let codeInt = json["code"] as? Int
            let isError = (codeStr != nil && codeStr != "OK" && codeStr != "ok" && codeStr != "0")
                        || (codeInt != nil && codeInt != 0 && codeInt != 200)
            if isError {
                let message = json["message"] as? String ?? (codeStr ?? "code=\(codeInt ?? -1)")
                throw DriveError.noPlayURL("阿里分享 token 获取失败：\(message)")
            }
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
        var request = URLRequest(url: URL(string: "https://api.alipan.com/adrive/v3/file/list")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(shareToken, forHTTPHeaderField: "x-share-token")
        request.setValue("https://www.alipan.com/", forHTTPHeaderField: "Referer")
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
        let url = URL(string: "https://api.alipan.com/adrive/v2/file/get_video_preview_play_info")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(shareToken, forHTTPHeaderField: "x-share-token")
        request.setValue("https://www.alipan.com/", forHTTPHeaderField: "Referer")
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

    private func aliGetDownloadURL(fileId: String, shareId: String, shareToken: String, token: String) async throws -> String {
        let url = URL(string: "https://api.alipan.com/adrive/v2/file/get_download_url")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(shareToken, forHTTPHeaderField: "x-share-token")
        request.setValue("https://www.alipan.com/", forHTTPHeaderField: "Referer")
        let body: [String: Any] = [
            "file_id": fileId,
            "share_id": shareId,
            "expire_sec": 14400
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        let respStr = String(data: data, encoding: .utf8) ?? ""
        print("[Ali] download_url 响应: \(respStr.prefix(500))")

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let code = json["code"] as? String, code != "OK" {
                let message = json["message"] as? String ?? "获取下载地址失败"
                print("[Ali] ⚠️ download_url API错误: \(message)")
                throw DriveError.noPlayURL("阿里 download_url: \(message)")
            }
            if let url = json["url"] as? String, !url.isEmpty {
                print("[Ali] ✅ download_url 获取成功")
                return url
            }
        }

        do {
            let result = try JSONDecoder().decode(AliDownloadURLResponse.self, from: data)
            if let downloadURL = result.url, !downloadURL.isEmpty {
                print("[Ali] ✅ download_url 获取成功")
                return downloadURL
            }
        } catch {
            print("[Ali] ⚠️ download_url JSON 解析失败: \(error)")
        }

        throw DriveError.noPlayURL("阿里: 未获取到 download_url")
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
            "Referer": "https://www.alipan.com/",
            "Origin": "https://www.alipan.com",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 AliApp(AYSD/6.0.0) Mobile/15E148",
            "Accept": "*/*",
            "Accept-Encoding": "identity"
        ]
    }

    // MARK: - 夸克网盘

    func resolveQuarkPlayURL(shareURL: String, cookie: String) async throws -> PlayResult {
        self.log("[Quark] 开始解析: \(shareURL)")
        let (pwdId, passcode) = quarkExtractShareInfo(shareURL: shareURL)
        self.log("[Quark] pwdId=\(pwdId), passcode=\(passcode.isEmpty ? "无" : "已传递")")
        guard !pwdId.isEmpty else {
            throw DriveError.invalidShareURL
        }

        var authCookie = cookie

        // 播放前检测夸克空间，快满时清理"来自：分享"目录
        authCookie = await quarkCleanShareOriginIfNeeded(cookie: authCookie, thresholdGB: 2.0)

        // 对齐 iBox：不创建自定义目录，to_pdir_fid 传 "0"，让夸克按默认行为保存
        let shareToken = try await quarkGetShareToken(pwdId: pwdId, passcode: passcode, cookie: authCookie)
        self.log("[Quark] stoken=\(shareToken.isEmpty ? "空" : "已获取")")

        let sourceFile = try await quarkFirstPlayableFile(pwdId: pwdId, stoken: shareToken, pdirFid: "0", cookie: authCookie)
        let fileExt = (sourceFile.fileName as NSString).pathExtension.lowercased()
        self.log("[Quark] 选中资源：\(sourceFile.fileName), fid=\(sourceFile.fid), 扩展名=\(fileExt)")

        // 先尝试命中转存 fid 缓存，避免同一资源重复转存
        var topLevelFids: [String]
        var isFileIdsFromCache = false
        if let cachedTopFids = quarkCachedSavedTopFids(pwdId: pwdId, sourceFid: sourceFile.fid, folderId: "0", cookie: authCookie), !cachedTopFids.isEmpty {
            topLevelFids = cachedTopFids
            isFileIdsFromCache = true
            self.log("[Quark] 转存完成 topLevelFids=\(topLevelFids), fileName=\(sourceFile.fileName)（来自缓存）")
        } else {
            topLevelFids = try await quarkSaveShare(
                pwdId: pwdId,
                stoken: shareToken,
                file: sourceFile,
                folderId: "0",
                cookie: authCookie
            )
            self.log("[Quark] 转存完成 topLevelFids=\(topLevelFids), fileName=\(sourceFile.fileName)")
            // 先按顶层 fid 缓存，后续确定实际播放文件 fid 后再更新 playbackFileId
            let currentCacheKey = quarkSavedFidCacheKey(pwdId: pwdId, sourceFid: sourceFile.fid, folderId: "0", cookie: authCookie)
            quarkStoreSavedItem(topLevelFids: topLevelFids, playbackFileId: nil, fileName: sourceFile.fileName, folderId: "0", cookie: authCookie, pwdId: pwdId, sourceFid: sourceFile.fid)
            // 转存成功即安排 1 小时后清理，不管后续播放是否成功
            scheduleCleanup(drive: .quark, fileIds: topLevelFids, token: authCookie, delay: 60 * 60)
            self.log("[Quark] 🧹 已安排转存文件 1 小时后清理")
            // 同时清理缓存中所有历史转存对象，只保留当前
            authCookie = await quarkCleanupPreviousSavedItems(excludingKey: currentCacheKey, cookie: authCookie)
        }

        guard var playbackFileId = topLevelFids.first else { throw DriveError.noPlayURL("夸克: 转存后未返回文件ID") }

        // 红色封面/被和谐资源的早期判断：转存返回 fileIds=["0"] 时，文件实际未真正保存到网盘
        let isPlaceholderFileId = playbackFileId == "0" || topLevelFids.allSatisfy({ $0 == "0" })
        if isPlaceholderFileId {
            self.log("[Quark] ⚠️ 转存返回占位 fileId=0，疑似资源已被和谐或转码失败")
            throw DriveError.noPlayURL("该资源在夸克网盘中已失效（可能被和谐或转码失败），请尝试其他资源")
        }

        // 轮询转存任务状态，等待文件落盘（对齐iBox抓包流程）
        if !isFileIdsFromCache, let taskId = quarkLastSaveTaskId {
            try await quarkPollTask(taskId: taskId, cookie: authCookie)
        }

        // 辅助：缓存命中后若后续确定了新的 playbackFileId，更新缓存
        func updateCachedPlaybackFileId(_ newPlaybackFileId: String) {
            guard !isFileIdsFromCache else { return }
            quarkStoreSavedItem(topLevelFids: topLevelFids, playbackFileId: newPlaybackFileId, fileName: sourceFile.fileName, folderId: "0", cookie: authCookie, pwdId: pwdId, sourceFid: sourceFile.fid)
        }

        // 获取会员信息（对齐iBox抓包：GET /member），用于判断清晰度权限
        if let memberType = await quarkGetMemberInfo(cookie: authCookie) {
            self.log("[Quark] 当前会员: \(memberType)，SVIP可使用原画download_url")
        }
        // 抓包里的实际播放主链路是：先调 v2/play 刷新 Video-Auth，再用 file/download 的 download_url 走 Range 播放。
        // v2/play 返回的 m3u8 只作为兜底，避免直接播放 m3u8 时分片未代理导致 403。
        var transcodeURL = ""
        var effectiveFileId = playbackFileId
        do {
            let playInfo = try await quarkRefreshVideoAuth(fileId: playbackFileId, cookie: authCookie)
            authCookie = playInfo.cookie
            transcodeURL = playInfo.playURL
            self.log("[Quark] v2/play 完成 hasVideoAuth=\(authCookie.contains("Video-Auth=")), transcodeURL=\(transcodeURL.isEmpty ? "空" : "已获取")")
        } catch {
            self.log("[Quark] ⚠️ v2/play 刷新 Video-Auth 失败，继续尝试 download_url: \(error.localizedDescription)")
        }

        var download: (url: String, fileName: String) = ("", "")
        do {
            download = try await quarkGetDownloadURL(fileId: playbackFileId, cookie: authCookie)
        } catch {
            let errMsg = error.localizedDescription
            self.log("[Quark] ⚠️ download_url 首次尝试失败(fid=\(playbackFileId)): \(errMsg)")
            // 文件ID可能不对（save_as_top_fids可能是文件夹ID），尝试通过文件名查找或重新转存
            if errMsg.contains("file not found") || errMsg.contains("not found") {
                if isFileIdsFromCache {
                    // 缓存的 fileId 已失效（可能被清理或过期），清除缓存并重新转存
                    self.log("[Quark] ⚠️ 缓存的 fileId 已失效，清除缓存并重新转存")
                    quarkInvalidateSavedFidCache(pwdId: pwdId, sourceFid: sourceFile.fid, folderId: "0", cookie: authCookie)
                    let newTopFids = try await quarkSaveShare(
                        pwdId: pwdId,
                        stoken: shareToken,
                        file: sourceFile,
                        folderId: "0",
                        cookie: authCookie
                    )
                    self.log("[Quark] 重新转存完成 topLevelFids=\(newTopFids), fileName=\(sourceFile.fileName)")
                    // 先缓存顶层对象，确定 playbackFileId 后再更新
                    let newCacheKey = quarkSavedFidCacheKey(pwdId: pwdId, sourceFid: sourceFile.fid, folderId: "0", cookie: authCookie)
                    quarkStoreSavedItem(topLevelFids: newTopFids, playbackFileId: nil, fileName: sourceFile.fileName, folderId: "0", cookie: authCookie, pwdId: pwdId, sourceFid: sourceFile.fid)
                    // 重新转存也安排清理
                    scheduleCleanup(drive: .quark, fileIds: newTopFids, token: authCookie, delay: 60 * 60)
                    self.log("[Quark] 🧹 已安排重新转存文件 1 小时后清理")
                    // 清理历史转存对象，只保留当前
                    authCookie = await quarkCleanupPreviousSavedItems(excludingKey: newCacheKey, cookie: authCookie)
                    // 标记为不再来自缓存，触发任务轮询
                    isFileIdsFromCache = false
                    if let taskId = quarkLastSaveTaskId {
                        try await quarkPollTask(taskId: taskId, cookie: authCookie)
                    }
                    if let newFileId = newTopFids.first, newFileId != "0" {
                        playbackFileId = newFileId
                        effectiveFileId = newFileId
                        download = (try? await quarkGetDownloadURL(fileId: newFileId, cookie: authCookie)) ?? ("", "")
                    }
                } else {
                    // 非缓存失效情况下 file not found，大概率是资源已被和谐或禁止播放，直接提示不再查找
                    self.log("[Quark] ⚠️ download_url 返回 file not found，判定资源已被和谐或禁止播放")
                    throw DriveError.noPlayURL("该资源已被和谐或禁止播放，请尝试其他资源")
                }
            }
            if download.url.isEmpty {
                // 如果转存拿到的是占位 fileId=0，且按文件名也找不到真实文件，说明资源本身已失效
                if isPlaceholderFileId {
                    throw DriveError.noPlayURL("该资源在夸克网盘中已失效（可能被和谐或转码失败），请尝试其他资源")
                }
                throw DriveError.noPlayURL("夸克 download_url 获取失败：\(errMsg)")
            }
        }
        let playURL: String
        let source: String
        if !download.url.isEmpty {
            playURL = download.url
            source = "download_url"
            self.log("[Quark] 📥 主线路: download_url (直链), host=\(URL(string: playURL)?.host ?? "unknown")")
        } else if !transcodeURL.isEmpty {
            playURL = transcodeURL
            source = "v2-play-fallback"
            self.log("[Quark] 📥 主线路: v2/play (转码m3u8, download_url为空), host=\(URL(string: playURL)?.host ?? "unknown")")
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

        self.log("[Quark] ✅ 主线路 source=\(source), host=\(URL(string: playURL)?.host ?? "unknown")")
        if let fallbackURL, let fallbackSource {
            self.log("[Quark] ✅ 兜底线路 source=\(fallbackSource), host=\(URL(string: fallbackURL)?.host ?? "unknown")")
        } else {
            self.log("[Quark] ⚠️ 兜底线路暂不可用")
        }

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

    /// 对齐 iBox parseFile(retry:) 机制：最多重试3次，指数退避（1s/2s/4s）
    private func resolveQuarkPlayURLWithRetry(shareURL: String, cookie: String, maxRetries: Int = 3) async throws -> PlayResult {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                let result = try await resolveQuarkPlayURL(shareURL: shareURL, cookie: cookie)
                if attempt > 0 {
                    self.log("[Quark] 🔄 重试第\(attempt)次成功")
                }
                return result
            } catch {
                lastError = error
                let errMsg = error.localizedDescription.lowercased()
                // 资源已失效、被和谐、禁止播放等确定性错误不重试
                let nonRetryable = errMsg.contains("已失效") || errMsg.contains("已被和谐") || errMsg.contains("禁止播放") || errMsg.contains("转存返回占位")
                if nonRetryable {
                    self.log("[Quark] 🚫 确定性错误，不再重试: \(error.localizedDescription)")
                    throw error
                }
                if attempt < maxRetries - 1 {
                    let delay = Double(1 << attempt) // 1s, 2s, 4s
                    self.log("[Quark] ⚠️ 第\(attempt + 1)次尝试失败: \(error.localizedDescription)，\(String(format: "%.0f", delay))秒后重试...")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        throw lastError ?? DriveError.noPlayURL("夸克播放解析失败（已重试\(maxRetries)次）")
    }

    struct QuarkShareFile {
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
        request.setValue("QingmanLslandApp/1.0", forHTTPHeaderField: "X-Client")
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

    /// 生成稳定的 X-Device-ID（对齐iBox原画抓包）
    private var quarkDeviceID: String {
        if let cached = UserDefaults.standard.string(forKey: "quark_device_id"), !cached.isEmpty {
            return cached
        }
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(id, forKey: "quark_device_id")
        return id
    }

    private func quarkPlaybackHeaders(cookie: String) -> [String: String] {
        // 对齐iBox 2.4.6：使用桌面端 Electron UA + iboxHeader 自定义头
        [
            "Cookie": cookie,
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch",
            "Referer": "https://pan.quark.cn/",
            "Origin": "https://pan.quark.cn",
            "Accept": "*/*",
            "Accept-Encoding": "identity",
            "X-Device-Id": quarkDeviceID,
            "X-Client": "QingmanLslandApp/1.0"
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

    /// 夸克账号维度的稳定Key，用于：
    /// 1) 缓存 vbox 目录fid；2) 单飞确保并发解析不会重复创建目录。
    private func quarkAccountKey(cookie: String) -> String {
        let dict = quarkCookieDictionary(from: cookie)
        // 优先用能代表账号身份的字段
        for key in ["__uid", "__puus", "__kps", "ctoken", "__sdid", "__kp"] {
            if let value = dict[key], !value.isEmpty {
                return "\(key):\(value)"
            }
        }
        // 兜底：cookie 哈希（避免把整段cookie当key导致过大/不稳定）
        return "cookie:\(baiduStableHash(cookie))"
    }

    /// 生成夸克账号唯一目录名，避免固定名称 vbox 在服务端产生同名冲突/隐藏状态（code=23008）
    /// 基于账号稳定标识生成，确保同一账号始终使用同一个目录
    private func quarkFolderName(cookie: String) -> String {
        let accountKey = quarkAccountKey(cookie: cookie)
        // 取账号key的哈希前缀，保证名称唯一且固定
        let hash = baiduStableHash(accountKey)
        let shortHash = String(hash.prefix(8))
        return "vbox_ios_\(shortHash)"
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
        self.log("[Quark] stoken诊断 length=\(st.count), hasPlus=\(hasPlus), hasSlash=\(hasSlash), hasEqual=\(hasEqual)")
        return st
    }

    private func quarkEnsureFolder(cookie: String) async throws -> String {
        (try await quarkEnsureFolderWithCookie(cookie: cookie)).folderId
    }


    private func quarkEnsureFolderWithCookie(cookie: String) async throws -> (folderId: String, cookie: String) {
        let accountKey = quarkAccountKey(cookie: cookie)
        let folderName = quarkFolderName(cookie: cookie)

        // 1. 优先使用缓存的 folderId（快速路径）
        quarkVboxCacheLock.lock()
        if let cachedFolderId = quarkVboxFolderCache[accountKey], !cachedFolderId.isEmpty {
            quarkVboxCacheLock.unlock()
            self.log("[Quark] 使用缓存 folderId=\(cachedFolderId) (folder=\(folderName))")
            return (cachedFolderId, cookie)
        }
        quarkVboxCacheLock.unlock()

        // 2. 缓存未命中：按账号唯一目录名查找根目录
        if let folder = try? await quarkFindVisibleFolder(cookie: cookie, folderName: folderName) {
            setQuarkVboxFolderCache(accountKey: accountKey, folderId: folder.folderId)
            return folder
        }

        // 3. 单飞：同一账号并发 ensure 时复用同一个 Task，避免重复创建目录导致 23008/同名冲突。
        quarkVboxCacheLock.lock()
        if let existing = quarkEnsureFolderTasks[accountKey] {
            quarkVboxCacheLock.unlock()
            return try await existing.value
        }

        let task = Task<(folderId: String, cookie: String), Error> { [weak self] in
            guard let self else { throw DriveError.noPlayURL("夸克：内部对象已释放") }
            do {
                let folder = try await self.quarkFindOrCreateVisibleFolder(cookie: cookie, folderName: folderName)
                self.setQuarkVboxFolderCache(accountKey: accountKey, folderId: folder.folderId)
                return folder
            } catch {
                self.log("[Quark] ❌ \(folderName) 目录创建/查找失败：\(error.localizedDescription)")
                throw error
            }
        }
        quarkEnsureFolderTasks[accountKey] = task
        quarkVboxCacheLock.unlock()

        defer {
            quarkVboxCacheLock.lock()
            quarkEnsureFolderTasks.removeValue(forKey: accountKey)
            quarkVboxCacheLock.unlock()
        }

        return try await task.value
    }

    /// 清理指定目录下的转存文件（对齐百度清理逻辑），不清理回收站

    /// 清理夸克"来自：分享"文件夹下的旧转存文件（夸克 sharepage/save 实际落盘位置）
    private func quarkCleanUpShareOriginFolder(cookie: String, excludeFileIds: [String] = []) async -> String {
        var currentCookie = cookie

        // 1. 用 quarkFindVisibleFolder 搜索「来自：分享」（兼容全角/半角冒号）
        var targetFid: String?
        for nameVariant in ["来自：分享", "来自:分享"] {
            if let (fid, mergedCookie) = try? await quarkFindVisibleFolder(
                cookie: currentCookie, folderName: nameVariant
            ) {
                targetFid = fid
                currentCookie = mergedCookie
                self.log("[Quark] 🔍 找到「\(nameVariant)」文件夹 fid=\(fid)")
                break
            }
        }
        guard let targetFid else {
            self.log("[Quark] ⚠️ quarkFindVisibleFolder 未找到「来自：分享」文件夹（尝试了全角/半角冒号），跳过清理")
            return currentCookie
        }

        // 2. 列出目录内容（含子目录递归）
        let listURL = quarkAPIURL("/1/clouddrive/file/sort")
        let pageSize = 200
        let maxPages = 10

        func extractFid(from item: [String: Any]) -> String? {
            for key in ["fid", "file_id", "obj_id", "id"] {
                if let value = item[key] as? String, !value.isEmpty { return value }
                if let value = item[key] as? Int { return String(value) }
            }
            return nil
        }

        func isItemDir(_ item: [String: Any]) -> Bool {
            return (item["file_type"] as? Int) == 0 || (item["is_dir"] as? Bool) == true
        }

        /// 递归收集指定目录下所有文件和子目录的 fid（排除 excludeSet 中的 fid）
        func collectFidsRecursive(dirFid: String, cookie: inout String, excludeSet: Set<String>) async -> (fids: [String], fileCount: Int, dirCount: Int) {
            var allFids: [String] = []
            var fileCount = 0
            var dirCount = 0

            for page in 1...maxPages {
                var request = URLRequest(url: listURL)
                request.httpMethod = "POST"
                quarkSetCommonHeaders(&request, cookie: cookie)
                let body: [String: Any] = [
                    "pdir_fid": dirFid,
                    "_sort": "file_type:asc,file_name:asc",
                    "_page": page,
                    "_size": pageSize,
                    "_fetch_total": 1
                ]
                request.httpBody = (try? JSONSerialization.data(withJSONObject: body))

                let (data, response): (Data, URLResponse)
                do {
                    (data, response) = try await session.data(for: request)
                } catch {
                    break
                }
                cookie = quarkMergeSetCookie(from: response, into: cookie)

                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataObj = json["data"] as? [String: Any],
                      let list = dataObj["list"] as? [[String: Any]] else { break }
                if list.isEmpty { break }

                for item in list {
                    guard let fid = extractFid(from: item), !fid.isEmpty, !excludeSet.contains(fid) else { continue }
                    allFids.append(fid)
                    if isItemDir(item) {
                        dirCount += 1
                        // 递归收集子目录中的内容
                        let sub = await collectFidsRecursive(dirFid: fid, cookie: &cookie, excludeSet: excludeSet)
                        allFids.append(contentsOf: sub.fids)
                        fileCount += sub.fileCount
                        dirCount += sub.dirCount
                    } else {
                        fileCount += 1
                    }
                }
                if list.count < pageSize { break }
            }

            return (allFids, fileCount, dirCount)
        }

        // 收集要删除的文件和文件夹，排除本次转存
        var fileIdsToDelete: [String] = []
        var deletedFileCount = 0
        var deletedDirCount = 0
        let excludeSet = Set(excludeFileIds)
        self.log("[Quark] 🔍 开始扫描「\"来自：分享\"」目录 (fid=\(targetFid))，排除 \(excludeFileIds.count) 个文件")

        let result = await collectFidsRecursive(dirFid: targetFid, cookie: &currentCookie, excludeSet: excludeSet)
        fileIdsToDelete = result.fids
        deletedFileCount = result.fileCount
        deletedDirCount = result.dirCount

        // 3. 删除旧文件和文件夹
        if !fileIdsToDelete.isEmpty {
            self.log("[Quark] 🔍 「来自：分享」目录: 待删除 \(deletedFileCount) 个旧文件 + \(deletedDirCount) 个旧文件夹")
            let deleteURL = quarkAPIURL("/1/clouddrive/file/delete")
            var deleteReq = URLRequest(url: deleteURL)
            deleteReq.httpMethod = "POST"
            quarkSetCommonHeaders(&deleteReq, cookie: currentCookie)
            let filelistJSON = (try? JSONSerialization.data(withJSONObject: fileIdsToDelete))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let deleteBody: [String: Any] = [
                "action_type": 2,
                "filelist": filelistJSON,
                "exclude_fids": []
            ]
            guard let deleteBodyData = try? JSONSerialization.data(withJSONObject: deleteBody) else {
                self.log("[Quark] ⚠️ 「来自：分享」清理删除Body序列化失败")
                return currentCookie
            }
            deleteReq.httpBody = deleteBodyData
            var deleteResult: (Data, URLResponse)?
            do {
                deleteResult = try await session.data(for: deleteReq)
            } catch {
                self.log("[Quark] ⚠️ 清理「\"来自：分享\"」目录删除请求失败: \(error.localizedDescription)")
                deleteResult = nil
            }
            if let deleteResp = deleteResult?.1 {
                currentCookie = quarkMergeSetCookie(from: deleteResp, into: currentCookie)
            }

            // 验证删除结果
            var deleteOK = true
            if let httpResp = deleteResult?.1 as? HTTPURLResponse {
                deleteOK = (200...299).contains(httpResp.statusCode)
            }
            if deleteOK, let deleteData = deleteResult?.0,
               let deleteJson = try? JSONSerialization.jsonObject(with: deleteData) as? [String: Any] {
                if let code = deleteJson["code"] as? Int, code != 0 {
                    deleteOK = false
                    self.log("[Quark] ⚠️ 「来自：分享」删除API返回错误: code=\(code), message=\(deleteJson["message"] ?? "nil")")
                }
            }
            if deleteOK {
                self.log("[Quark] ✅ 已清理「\"来自：分享\"」目录下 \(deletedFileCount) 个旧文件 + \(deletedDirCount) 个旧文件夹")
            }

            // 4. 彻底清理回收站
            if let deleteData = deleteResult?.0,
               let deleteJson = try? JSONSerialization.jsonObject(with: deleteData) as? [String: Any],
               let taskId = deleteJson["task_id"] as? String {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let recycleURL = quarkAPIURL("/1/clouddrive/file/recycle/list", extra: [
                    URLQueryItem(name: "_page", value: "1"),
                    URLQueryItem(name: "_size", value: "100"),
                    URLQueryItem(name: "_sort", value: "move_recycle_at:desc")
                ])
                var recycleReq = URLRequest(url: recycleURL)
                recycleReq.httpMethod = "GET"
                recycleReq.timeoutInterval = 10
                quarkSetCommonHeaders(&recycleReq, cookie: currentCookie)

                let recycleResult = try? await session.data(for: recycleReq)
                if let recycleResp = recycleResult?.1 {
                    currentCookie = quarkMergeSetCookie(from: recycleResp, into: currentCookie)
                }
                if let recycleData = recycleResult?.0,
                   let recycleJSON = try? JSONSerialization.jsonObject(with: recycleData) as? [String: Any],
                   let recycleList = recycleJSON["data"] as? [[String: Any]] {
                    let recordIds = recycleList.compactMap { item -> String? in
                        let recordId = item["record_id"] as? String ?? ""
                        if recordId.contains(taskId) || fileIdsToDelete.contains(where: { recordId.contains($0) }) {
                            return recordId
                        }
                        return nil
                    }
                    if !recordIds.isEmpty {
                        let removeURL = quarkAPIURL("/1/clouddrive/file/recycle/remove")
                        var removeReq = URLRequest(url: removeURL)
                        removeReq.httpMethod = "POST"
                        quarkSetCommonHeaders(&removeReq, cookie: currentCookie)
                        let removeBody: [String: Any] = ["select_mode": 2, "record_list": recordIds]
                        removeReq.httpBody = try? JSONSerialization.data(withJSONObject: removeBody)
                        let removeResult = try? await session.data(for: removeReq)
                        if let removeResp = removeResult?.1 {
                            currentCookie = quarkMergeSetCookie(from: removeResp, into: currentCookie)
                        }
                        self.log("[Quark] ✅ 已彻底清理回收站 \(recordIds.count) 条记录（来自：分享）")
                    }
                }
            }
        } else {
            self.log("[Quark] ℹ️ 「\"来自：分享\"」目录无可清理的旧文件")
        }

        return currentCookie
    }

    /// 查询夸克网盘容量信息
    private func quarkGetQuotaInfo(cookie: String) async -> (used: Int64, total: Int64, cookie: String) {
        var currentCookie = cookie

        // 对齐 iBox 2.4.6：先通过 member 接口取 capacity 字段（最稳定，不需要 UC 账号）
        if let memberQuota = await quarkGetQuotaFromMember(cookie: currentCookie),
           memberQuota.total > 0 {
            return (memberQuota.used, memberQuota.total, currentCookie)
        }

        // member 失败再尝试标准 quota 端点（只使用夸克域名，避免 UC 域名 cookie 不匹配导致 401）
        let ut = String(Int(Date().timeIntervalSince1970 * 1000))
        let endpoints = [
            ("https://drive-pc.quark.cn", "/1/clouddrive/quota/info", "pr=ucpro&fr=pc&uc_param_str=&ut=\(ut)"),
        ]

        for (host, path, query) in endpoints {
            guard let url = URL(string: "\(host)\(path)?\(query)") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            quarkSetCommonHeaders(&request, cookie: cookie)
            // iBox 抓包显示 quota/info 需要 dlt_keys 字段，否则返回 405/参数错误
            let body: [String: Any] = ["dlt_keys": ["uc_nor_dlt"]]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            guard let (data, response) = try? await session.data(for: request) else {
                self.log("[Quark] ⚠️ quota端点 \(host) 请求失败")
                continue
            }
            currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)

            let rawBody = String(data: data, encoding: .utf8) ?? "<非UTF8>"
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            self.log("[Quark] 📊 quota端点 \(host) HTTP \(statusCode), 原始响应: \(rawBody.prefix(600))")
            guard statusCode == 200 || statusCode == 201 else {
                self.log("[Quark] ⚠️ quota端点 \(host) 非 200 响应，跳过")
                continue
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.log("[Quark] ⚠️ quota端点 \(host) 响应不是JSON: \(rawBody.prefix(500))")
                continue
            }

            // 容量字段可能在 data 下，也可能在更深层；兜底直接使用顶层 json
            let dataObj = json["data"] as? [String: Any]
            let capObj: [String: Any] = dataObj?["capinfo"] as? [String: Any]
                ?? dataObj?["capacity"] as? [String: Any]
                ?? dataObj?["account_capacity"] as? [String: Any]
                ?? json

            func parseInt64(_ value: Any?) -> Int64 {
                if let v = value as? Int64 { return v }
                if let v = value as? Int { return Int64(v) }
                if let v = value as? Double { return Int64(v) }
                if let v = value as? String { return Int64(v) ?? 0 }
                return 0
            }

            let used = parseInt64(capObj["used"] ?? capObj["size_used"] ?? dataObj?["used"])
            var total = parseInt64(capObj["total"] ?? capObj["size_total"] ?? dataObj?["total"])
            // 只有剩余量时，用 account.total_capacity 兜底
            if total <= 0, let account = dataObj?["account"] as? [String: Any] {
                total = parseInt64(account["total_capacity"] ?? account["capacity_total"] ?? account["total"])
            }
            if total > 0 {
                self.log("[Quark] ✅ quota端点 \(host) 成功: used=\(used), total=\(total)")
                return (used, total, currentCookie)
            }
            self.log("[Quark] ⚠️ quota端点 \(host) total=0，原始响应: \(rawBody.prefix(500))")
        }

        self.log("[Quark] ⚠️ 所有quota端点均失败")
        return (0, 0, currentCookie)
    }

    /// 兜底：通过 member 接口获取容量信息（对齐 iBox 2.4.6）
    private func quarkGetQuotaFromMember(cookie: String) async -> (used: Int64, total: Int64)? {
        let url = quarkAPIURL("/1/clouddrive/member", extra: [
            URLQueryItem(name: "fetch_subscribe", value: "true"),
            URLQueryItem(name: "fetch_identity", value: "true"),
            URLQueryItem(name: "_ch", value: "home"),
            URLQueryItem(name: "ve", value: "3.19.0")
        ])
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        quarkSetCommonHeaders(&req, cookie: cookie)

        do {
            let (data, _) = try await session.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["data"] as? [String: Any] {
                func p(_ v: Any?) -> Int64 {
                    if let v = v as? Int64 { return v }
                    if let v = v as? Int { return Int64(v) }
                    if let v = v as? Double { return Int64(v) }
                    if let v = v as? String { return Int64(v) ?? 0 }
                    return 0
                }
                // 夸克 member 接口可能把容量放在 capacity 或 capinfo 字段
                let cap = d["capacity"] as? [String: Any]
                    ?? d["capinfo"] as? [String: Any]
                    ?? d["account_capacity"] as? [String: Any]
                var used = p(cap?["used"] ?? cap?["size_used"] ?? d["used"] ?? 0)
                var total = p(cap?["total"] ?? cap?["size_total"] ?? d["total"] ?? 0)

                // 有些接口 capacity 只给剩余，需要拿 account 字段的总容量
                if total <= 0, let account = d["account"] as? [String: Any] {
                    total = p(account["total_capacity"] ?? account["capacity_total"] ?? account["total"] ?? 0)
                }
                if used <= 0, let account = d["account"] as? [String: Any] {
                    used = p(account["used_capacity"] ?? account["capacity_used"] ?? account["used"] ?? 0)
                }

                // 如果只有 total，尝试用 d["remain"] 推算 used
                if total > 0 && used <= 0, let remain = d["remain"] {
                    used = total - p(remain)
                }

                if total > 0 {
                    self.log("[Quark] ✅ member 获取容量成功: used=\(used), total=\(total)")
                    return (used, total)
                } else {
                    let raw = String(data: data, encoding: .utf8) ?? "<非UTF8>"
                    self.log("[Quark] ⚠️ member 接口未返回有效容量，原始响应: \(raw.prefix(800))")
                }
            } else {
                let raw = String(data: data, encoding: .utf8) ?? "<非UTF8>"
                self.log("[Quark] ⚠️ member 接口响应异常，原始响应: \(raw.prefix(800))")
            }
        } catch {
            self.log("[Quark] ⚠️ member 兜底容量获取失败: \(error.localizedDescription)")
        }
        return nil
    }

    /// 如果剩余空间不足，清理"来自：分享"目录下所有文件
    private func quarkCleanShareOriginIfNeeded(cookie: String, thresholdGB: Double = 1.0) async -> String {
        self.log("[Quark] 🧹 开始容量检测...")
        var currentCookie = cookie
        let (used, total, mergedCookie) = await quarkGetQuotaInfo(cookie: currentCookie)
        currentCookie = mergedCookie

        let quotaAvailable = total > 0
        var freeGB: Double = 0
        if quotaAvailable {
            let free = total - used
            freeGB = Double(free) / 1_073_741_824.0
            let totalGB = Double(total) / 1_073_741_824.0
            let usedGB = Double(used) / 1_073_741_824.0
            let usedPercent = Double(used) * 100.0 / Double(total)

            self.log("[Quark] 📊 容量检测: 已用 \(String(format: "%.2f", usedGB))GB / 总共 \(String(format: "%.2f", totalGB))GB (\(String(format: "%.1f", usedPercent))%)，剩余 \(String(format: "%.2f", freeGB))GB，清理阈值 \(thresholdGB)GB")
        }

        if quotaAvailable {
            // 剩余空间低于阈值时触发清理
            guard freeGB < thresholdGB else {
                self.log("[Quark] ✅ 剩余空间充足(\(String(format: "%.2f", freeGB))GB >= \(thresholdGB)GB)，跳过清理")
                return currentCookie
            }
            self.log("[Quark] 🧹 剩余空间不足 \(String(format: "%.2f", freeGB))GB < \(thresholdGB)GB，开始清理夸克转存文件")
        } else {
            self.log("[Quark] ⚠️ 无法获取夸克容量信息（member+quota端点均失败），按保守策略清理最近转存的文件")
        }

        // 辅助：用 GET 列出目录下所有文件/文件夹
        func collectFids(folderId: String, onlyVideo: Bool = false, limit: Int? = nil, includeFolders: Bool = false) async -> [String] {
            var fids: [String] = []
            let pageSize = 200
            let maxPages = limit != nil ? min(10, (limit! + pageSize - 1) / pageSize) : 10
            for page in 1...maxPages {
                let extra = [
                    URLQueryItem(name: "pdir_fid", value: folderId),
                    URLQueryItem(name: "_sort", value: "file_type:asc,updated_at:desc"),
                    URLQueryItem(name: "_page", value: String(page)),
                    URLQueryItem(name: "_size", value: String(pageSize)),
                    URLQueryItem(name: "_fetch_total", value: "1")
                ]
                let listURL = quarkAPIURL("/1/clouddrive/file/sort", extra: extra)
                var request = URLRequest(url: listURL)
                request.httpMethod = "GET"
                request.timeoutInterval = 15
                quarkSetCommonHeaders(&request, cookie: currentCookie)

                guard let (data, response) = try? await session.data(for: request) else {
                    self.log("[Quark] ⚠️ file/sort 请求失败 folderId=\(folderId), page=\(page)")
                    break
                }
                currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataObj = json["data"] as? [String: Any],
                      let list = dataObj["list"] as? [[String: Any]] else {
                    let raw = String(data: data, encoding: .utf8) ?? "<非UTF8>"
                    self.log("[Quark] ⚠️ file/sort 解析失败 folderId=\(folderId), page=\(page), raw=\(raw.prefix(300))")
                    break
                }
                let total = dataObj["_total"] as? Int ?? dataObj["total"] as? Int ?? -1
                self.log("[Quark] 📂 file/sort folderId=\(folderId), page=\(page), 返回 \(list.count) 项, total=\(total)")
                if list.isEmpty { break }

                for item in list {
                    let isDir = (item["file_type"] as? Int) == 0 || (item["is_dir"] as? Bool) == true

                    // 默认跳过文件夹；明确 includeFolders 时收集文件夹 fid
                    if isDir && !includeFolders { continue }

                    // 如仅需视频，过滤后缀（文件夹不应用视频后缀过滤）
                    if onlyVideo && !isDir {
                        let name = (item["file_name"] as? String ?? item["name"] as? String ?? "").lowercased()
                        let videoExts = [".mp4", ".mkv", ".avi", ".ts", ".mov", ".flv", ".wmv", ".m4v", ".3gp"]
                        guard videoExts.contains(where: { name.hasSuffix($0) }) else { continue }
                    }

                    for key in ["fid", "file_id"] {
                        if let fid = item[key] as? String, !fid.isEmpty {
                            fids.append(fid)
                            break
                        } else if let fid = item[key] as? Int {
                            fids.append(String(fid))
                            break
                        }
                    }

                    if let limit = limit, fids.count >= limit {
                        break
                    }
                }
                if list.count < pageSize { break }
                if let limit = limit, fids.count >= limit { break }
            }
            return fids
        }

        // 辅助：批量删除 fileIds（受保护的 fid 不删除）
        func deleteFids(_ fids: [String], excludeFids: Set<String> = []) async -> Int {
            let fidsToDelete = fids.filter { !excludeFids.contains($0) }
            guard !fidsToDelete.isEmpty else { return 0 }
            let batchSize = 100
            var deletedCount = 0
            for i in stride(from: 0, to: fidsToDelete.count, by: batchSize) {
                let batch = Array(fidsToDelete[i..<min(i + batchSize, fidsToDelete.count)])
                let deleteURL = quarkAPIURL("/1/clouddrive/file/delete")
                var deleteReq = URLRequest(url: deleteURL)
                deleteReq.httpMethod = "POST"
                quarkSetCommonHeaders(&deleteReq, cookie: currentCookie)
                let deleteBody: [String: Any] = [
                    "action_type": 2,
                    "filelist": batch,
                    "exclude_fids": []
                ]
                guard let bodyData = try? JSONSerialization.data(withJSONObject: deleteBody) else { continue }
                deleteReq.httpBody = bodyData

                if let (data, response) = try? await session.data(for: deleteReq) {
                    currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let code = json["code"] as? Int, code == 0 {
                        deletedCount += batch.count
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms 间隔，避免风控
            }
            return deletedCount
        }

        // 辅助：收集所有缓存中未过期的对象 fid，避免播放前清理误删正在使用的转存文件
        func protectedCachedFileIds() -> Set<String> {
            let cache = loadQuarkSavedFidCache()
            let now = Date()
            var fids = Set<String>()
            for item in cache.values where item.expiresAt > now {
                item.topLevelFids.forEach { fids.insert($0) }
                if let playbackFileId = item.playbackFileId {
                    fids.insert(playbackFileId)
                }
            }
            return fids
        }

        // 辅助：查找文件夹 fid
        func findFolderId(name: String) async -> String? {
            let searchExtra = [
                URLQueryItem(name: "pdir_fid", value: "0"),
                URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc"),
                URLQueryItem(name: "_page", value: "1"),
                URLQueryItem(name: "_size", value: "200"),
                URLQueryItem(name: "_fetch_total", value: "1")
            ]
            let searchURL = quarkAPIURL("/1/clouddrive/file/sort", extra: searchExtra)
            var searchReq = URLRequest(url: searchURL)
            searchReq.httpMethod = "GET"
            searchReq.timeoutInterval = 15
            quarkSetCommonHeaders(&searchReq, cookie: currentCookie)

            guard let (data, response) = try? await session.data(for: searchReq) else { return nil }
            currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let dataObj = json["data"] as? [String: Any],
                  let list = dataObj["list"] as? [[String: Any]] else { return nil }

            let targetName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            for item in list {
                let itemName = (item["file_name"] as? String ?? item["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard itemName == targetName else { continue }
                if let fid = item["fid"] as? String, !fid.isEmpty { return fid }
                if let fid = item["file_id"] as? String, !fid.isEmpty { return fid }
                if let fid = item["fid"] as? Int { return String(fid) }
            }
            return nil
        }

        var totalDeleted = 0

        // 同时扫描"来自：分享"目录和根目录视频文件（并行）
        async let shareFids: [String] = {
            for nameVariant in ["来自：分享", "来自:分享", "来自分享的文件", "来自分享"] {
                if let fid = await findFolderId(name: nameVariant) {
                    self.log("[Quark] 🔍 找到清理目标目录「\(nameVariant)」fid=\(fid)")
                    // 分享目录内同时清理子文件夹和文件，避免文件夹形式转存残留
                    return await collectFids(folderId: fid, includeFolders: true)
                }
            }
            return []
        }()
        // 容量检测成功或失败都清理根目录视频；失败时更激进，清理最新 100 个避免空间爆掉
        async let rootFids: [String] = quotaAvailable
            ? collectFids(folderId: "0", onlyVideo: true)
            : collectFids(folderId: "0", onlyVideo: true, limit: 100)

        let shareResult = await shareFids
        let rootResult = await rootFids

        if quotaAvailable {
            self.log("[Quark] 📋 扫描结果：来自分享 \(shareResult.count) 个文件，根目录 \(rootResult.count) 个视频文件")
        } else {
            self.log("[Quark] 📋 容量未知，保守清理：来自分享 \(shareResult.count) 个文件，根目录最新 \(rootResult.count) 个视频文件")
        }

        // 合并去重后批量删除，排除缓存中未过期的 fileId（避免误删正在播放或待播放的转存文件）
        let allFids = Array(Set(shareResult + rootResult))
        let protectedFids = protectedCachedFileIds()
        if !allFids.isEmpty {
            totalDeleted = await deleteFids(allFids, excludeFids: protectedFids)
            self.log("[Quark] ✅ 已清理 \(totalDeleted)/\(allFids.count) 个文件（来自分享 + 根目录，保护缓存 \(protectedFids.count) 个）")
        }

        self.log("[Quark] ✅ 空间清理完成，共删除 \(totalDeleted) 个文件")
        return currentCookie
    }

    private func quarkFindOrCreateVisibleFolder(cookie: String, folderName: String) async throws -> (folderId: String, cookie: String) {
        // 先查找已存在的目录
        if let folder = try await quarkFindVisibleFolder(cookie: cookie, folderName: folderName) {
            self.log("[Quark] 使用根目录 \(folderName) 文件夹 fid=\(folder.folderId)")
            return folder
        }

        // 尝试创建目录
        let createURL = quarkAPIURL("/1/clouddrive/file")
        var request = URLRequest(url: createURL)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie)
        let body: [String: Any] = [
            "pdir_fid": "0",
            "file_name": folderName,
            "dir": true,
            "dir_path": ""
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let mergedCookie = quarkMergeSetCookie(from: response, into: cookie)
        let preview = String(data: data.prefix(500), encoding: .utf8) ?? ""
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self.log("[Quark] ❌ 创建 \(folderName) 目录响应非JSON: \(preview)")
            throw DriveError.invalidResponse
        }

        // 创建成功，提取fid
        if let fid = quarkExtractFirstFid(from: json), !fid.isEmpty {
            self.log("[Quark] ✅ 已创建根目录 \(folderName) 文件夹 fid=\(fid)")
            return (fid, mergedCookie)
        }

        // 检查是否因为"已存在"而失败（覆盖夸克API各种返回格式）
        let message = (json["message"] as? String ?? json["msg"] as? String ?? "").lowercased()
        let code = json["code"] as? Int ?? json["status"] as? Int ?? 0
        // 把“同名冲突/下载中”等视为瞬态问题，等待并重试查找即可恢复
        let isAlreadyExists = message.contains("已存在")
            || message.contains("exist")
            || message.contains("同名")
            || message.contains("already")
            || message.contains("重复")
            || message.contains("冲突")
            || message.contains("downloading")
            || message.contains("file is downloading")
            || code == 23008
            || code == 40003
            || code == 40001
            || code == 40005

        if isAlreadyExists {
            self.log("[Quark] ⚠️ \(folderName) 目录疑似已存在/处理中(code=\(code), message=\(message))，尝试重新查找...")
            // 目录“已存在”但 file/sort 可能存在短暂不可见（或缓存延迟），做几次短重试
            for attempt in 1...5 {
                if attempt > 1 {
                    try? await Task.sleep(nanoseconds: UInt64(200_000_000 * attempt))
                }
                if let folder = try await quarkFindVisibleFolder(cookie: mergedCookie, folderName: folderName) {
                    self.log("[Quark] ✅ 找到已存在的 \(folderName) 文件夹 fid=\(folder.folderId) (attempt=\(attempt))")
                    return folder
                }
            }

            // 兜底：某些环境下根目录 file/sort 返回结构/字段不稳定，尝试用另一套分页参数再按名称查一次。
            if let fid = await quarkFindSavedFileId(fileName: folderName, folderId: "0", cookie: mergedCookie) {
                self.log("[Quark] ✅ 兜底：按名称在根目录定位 \(folderName)，fid=\(fid)")
                return (fid, mergedCookie)
            }
            self.log("[Quark] ⚠️ 标记已存在但 file/sort 仍找不到，尝试从创建响应取 fid...")
            if let fid = quarkExtractFirstFid(from: json), !fid.isEmpty {
                self.log("[Quark] ✅ 从创建响应提取到 fid=\(fid)")
                return (fid, mergedCookie)
            }
            self.log("[Quark] ⚠️ 创建响应也没有 fid，查看完整响应诊断: \(preview)")
        }

        if code != 0 && code != 200 {
            self.log("[Quark] ❌ 创建 \(folderName) 目录失败: message=\(message), code=\(code), preview=\(preview)")
            throw DriveError.noPlayURL("夸克创建 \(folderName) 目录失败：\(message) (code=\(code))")
        }

        self.log("[Quark] ❌ 创建 \(folderName) 目录成功(status=\(code))但未返回 fid: \(preview)")
        throw DriveError.noPlayURL("夸克创建 \(folderName) 目录后未返回 fid")
    }

    private func quarkFindVisibleFolder(cookie: String, folderName: String) async throws -> (folderId: String, cookie: String)? {
        let listURL = quarkAPIURL("/1/clouddrive/file/sort")
        var currentCookie = cookie
        let pageSize = 200
        let maxPages = 200
        let targetName = folderName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        func extractName(from item: [String: Any]) -> String {
            if let value = item["file_name"] as? String, !value.isEmpty { return value }
            if let value = item["name"] as? String, !value.isEmpty { return value }
            if let value = item["fileName"] as? String, !value.isEmpty { return value }
            if let value = item["title"] as? String, !value.isEmpty { return value }
            return ""
        }

        func extractFolderId(from item: [String: Any]) -> String? {
            for key in ["fid", "file_id", "obj_id", "id"] {
                if let value = item[key] as? String, !value.isEmpty { return value }
                if let value = item[key] as? Int { return String(value) }
            }
            return nil
        }

        func looksLikeDirectory(_ item: [String: Any]) -> Bool {
            if let b = item["dir"] as? Bool { return b }
            if let i = item["dir"] as? Int { return i != 0 }
            if let s = item["dir"] as? String {
                let v = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return v == "1" || v == "true" || v == "yes"
            }
            if let file = item["file"] as? Bool { return file == false }
            if let fileType = item["file_type"] as? Int { return fileType == 0 }
            if let category = item["category"] as? String {
                let lowered = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if lowered == "folder" || lowered == "dir" || lowered == "directory" {
                    return true
                }
            }
            return false
        }

        func fetchList(page: Int, underscoreStyle: Bool) async throws -> ([[String: Any]]?, Int?, String?, String) {
            var request = URLRequest(url: listURL)
            request.httpMethod = "POST"
            quarkSetCommonHeaders(&request, cookie: currentCookie)
            let body: [String: Any]
            if underscoreStyle {
                // 版本A：参数带下划线（目前大部分接口使用这一套）
                body = [
                    "pdir_fid": "0",
                    "_sort": "file_type:asc,file_name:asc",
                    "_page": page,
                    "_size": pageSize,
                    "_fetch_total": 1
                ]
            } else {
                // 版本B：参数不带下划线（部分环境/接口返回结构更稳定）
                body = [
                    "pdir_fid": "0",
                    "sort_by": "file_name",
                    "sort_order": "asc",
                    "page": page,
                    "size": pageSize
                ]
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: request)
            currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? ""
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (nil, nil, nil, preview)
            }
            let code = json["code"] as? Int ?? (json["status"] as? Int)
            let message = json["message"] as? String ?? json["msg"] as? String
            if let code, code != 0 && code != 200 {
                return (nil, code, message, preview)
            }
            guard let dataObj = json["data"] as? [String: Any],
                  let list = dataObj["list"] as? [[String: Any]] else {
                return (nil, code, message, preview)
            }
            return (list, code, message, preview)
        }

        // 核心策略：先按名称匹配目标目录，命中后再提取 fid；并对两种分页参数风格做兼容兜底。
        for underscoreStyle in [true, false] {
            for page in 1...maxPages {
                let (listOpt, codeOpt, messageOpt, preview) = try await fetchList(page: page, underscoreStyle: underscoreStyle)
                guard let list = listOpt else {
                    if let codeOpt, let messageOpt {
                        self.log("[Quark] ⚠️ 根目录列表返回异常 style=\(underscoreStyle ? "underscore" : "plain") code=\(codeOpt) message=\(messageOpt)，preview=\(preview)")
                    } else {
                        self.log("[Quark] ⚠️ 根目录列表结构异常 style=\(underscoreStyle ? "underscore" : "plain")，preview=\(preview)")
                    }
                    break
                }

                self.log("[Quark] 根目录扫描 style=\(underscoreStyle ? "underscore" : "plain") page=\(page), count=\(list.count)")
                for item in list {
                    let name = extractName(from: item)
                    guard name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == targetName else { continue }
                    if let folderId = extractFolderId(from: item) {
                        if looksLikeDirectory(item) {
                            self.log("[Quark] ✅ 根目录命中 \(folderName) 文件夹 fid=\(folderId)")
                        } else {
                            self.log("[Quark] ⚠️ 命中名称为 \(folderName) 的对象，但目录字段不典型，仍先使用 fid=\(folderId), item=\(item)")
                        }
                        return (folderId, currentCookie)
                    } else {
                        self.log("[Quark] ⚠️ 命中 \(folderName) 但未提取到 fid，item=\(item)")
                    }
                }

                if list.count < pageSize { break }
            }
        }

        return nil
    }

    private func quarkExtractFirstFid(from value: Any) -> String? {
        if let dict = value as? [String: Any] {
            for key in ["fid", "file_id", "pdir_fid", "obj_id", "target_fid", "conflict_fid", "exist_fid", "id"] {
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

    /// 夸克转存任务ID，用于轮询任务状态
    private var quarkLastSaveTaskId: String?

    /// 轮询夸克转存任务状态，等待文件落盘（对齐iBox抓包：GET /1/clouddrive/task）
    private func quarkPollTask(taskId: String, cookie: String, maxRetries: Int = 10, interval: TimeInterval = 1.0) async throws {
        self.log("[Quark] ⏳ 轮询转存任务状态: \(taskId)")
        for i in 0..<maxRetries {
            let url = quarkAPIURL("/1/clouddrive/task", extra: [
                URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000))),
                URLQueryItem(name: "task_id", value: taskId),
                URLQueryItem(name: "retry_index", value: "0")
            ])
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 10
            quarkSetCommonHeaders(&req, cookie: cookie)

            let (data, _) = try await session.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["data"] as? [String: Any] {
                let status = d["status"] as? Int ?? -1
                let finish = d["finish"] as? Bool ?? false
                if finish || status == 2 {
                    self.log("[Quark] ✅ 转存任务完成: status=\(status), finish=\(finish)")
                    return
                }
                if status == 3 || status == -1 {
                    self.log("[Quark] ⚠️ 转存任务异常: status=\(status)，继续尝试播放")
                    return
                }
            }
            if i < maxRetries - 1 {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        self.log("[Quark] ⚠️ 转存任务轮询超时，继续尝试播放")
    }

    /// 获取夸克会员信息（对齐iBox抓包：GET /1/clouddrive/member）
    private func quarkGetMemberInfo(cookie: String) async -> String? {
        let url = quarkAPIURL("/1/clouddrive/member", extra: [
            URLQueryItem(name: "fetch_subscribe", value: "true"),
            URLQueryItem(name: "fetch_identity", value: "true"),
            URLQueryItem(name: "_ch", value: "home"),
            URLQueryItem(name: "ve", value: "3.19.0")
        ])
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        quarkSetCommonHeaders(&req, cookie: cookie)

        do {
            let (data, _) = try await session.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = json["data"] as? [String: Any] {
                let memberType = d["member_type"] as? String ?? "normal"
                self.log("[Quark] 会员类型: \(memberType)")
                return memberType
            }
        } catch {
            self.log("[Quark] 获取会员信息失败: \(error.localizedDescription)")
        }
        return nil
    }

    private func quarkDeleteFiles(fileIds: [String], cookie: String) async -> String {
        guard !fileIds.isEmpty else { return cookie }
        var currentCookie = cookie
        let url = quarkAPIURL("/1/clouddrive/file/delete")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        quarkSetCommonHeaders(&req, cookie: currentCookie)
        // 对齐 iBox：filelist 字段传字符串数组
        let body: [String: Any] = ["action_type": 2, "filelist": fileIds, "exclude_fids": []]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let deleteResult = try? await session.data(for: req)
        if let response = deleteResult?.1 {
            currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)
        }
        self.log("[CloudDrive] ✅ 夸克已提交删除 \(fileIds.count) 个转存文件")

        // 彻底清理回收站（对齐iBox抓包：先 recycle/list 再 recycle/remove）
        if let data = deleteResult?.0,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let taskId = json["task_id"] as? String {
            // 等待删除任务完成
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // 查询回收站找到对应的记录
            let recycleURL = quarkAPIURL("/1/clouddrive/file/recycle/list", extra: [
                URLQueryItem(name: "_page", value: "1"),
                URLQueryItem(name: "_size", value: "100"),
                URLQueryItem(name: "_sort", value: "move_recycle_at:desc")
            ])
            var recycleReq = URLRequest(url: recycleURL)
            recycleReq.httpMethod = "GET"
            recycleReq.timeoutInterval = 10
            quarkSetCommonHeaders(&recycleReq, cookie: currentCookie)

            let recycleResult = try? await session.data(for: recycleReq)
            if let response = recycleResult?.1 {
                currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)
            }
            if let recycleData = recycleResult?.0,
               let recycleJSON = try? JSONSerialization.jsonObject(with: recycleData) as? [String: Any],
               let list = recycleJSON["data"] as? [[String: Any]] {
                // 找到刚删除的文件记录
                let recordIds = list.compactMap { item -> String? in
                    // record_id 格式: "taskId-fid-时间-recycleV2"
                    let recordId = item["record_id"] as? String ?? ""
                    if recordId.contains(taskId) || fileIds.contains(where: { recordId.contains($0) }) {
                        return recordId
                    }
                    return nil
                }
                if !recordIds.isEmpty {
                    let removeURL = quarkAPIURL("/1/clouddrive/file/recycle/remove")
                    var removeReq = URLRequest(url: removeURL)
                    removeReq.httpMethod = "POST"
                    quarkSetCommonHeaders(&removeReq, cookie: currentCookie)
                    let removeBody: [String: Any] = ["select_mode": 2, "record_list": recordIds]
                    removeReq.httpBody = try? JSONSerialization.data(withJSONObject: removeBody)
                    let removeResult = try? await session.data(for: removeReq)
                    if let response = removeResult?.1 {
                        currentCookie = quarkMergeSetCookie(from: response, into: currentCookie)
                    }
                    self.log("[CloudDrive] ✅ 夸克已彻底清理回收站 \(recordIds.count) 条记录")
                }
            }
        }
        return currentCookie
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

    // MARK: - 夸克网盘完整文件列表获取
    func quarkGetFileList(shareURL: String, cookie: String) async throws -> [QuarkShareFile] {
        let (pwdId, passcode) = quarkExtractShareInfo(shareURL: shareURL)
        guard !pwdId.isEmpty else { throw DriveError.invalidShareURL }

        var authCookie = cookie
        let shareToken = try await quarkGetShareToken(pwdId: pwdId, passcode: passcode, cookie: authCookie)

        var allPlayable: [QuarkShareFile] = []
        try await quarkCollectAllPlayableFiles(pwdId: pwdId, stoken: shareToken, pdirFid: "0", cookie: authCookie, result: &allPlayable)
        return allPlayable
    }

    private func quarkCollectAllPlayableFiles(pwdId: String, stoken: String, pdirFid: String, cookie: String, result: inout [QuarkShareFile]) async throws {
        var page = 1
        var hasMore = true
        while hasMore {
            let files = try await quarkGetShareDetail(pwdId: pwdId, stoken: stoken, pdirFid: pdirFid, cookie: cookie, page: page)
            for file in files where !file.isDir && quarkIsPlayableFileName(file.fileName) {
                result.append(file)
            }
            // 收集子目录，稍后递归
            var subDirs: [QuarkShareFile] = []
            for file in files where file.isDir {
                subDirs.append(file)
            }
            // 递归进入子目录
            for dir in subDirs {
                try await quarkCollectAllPlayableFiles(pwdId: pwdId, stoken: stoken, pdirFid: dir.fid, cookie: cookie, result: &result)
            }
            hasMore = files.count >= 100
            page += 1
            if page > 20 { break } // 安全限制，最多20页
        }
    }

    private func quarkGetShareDetail(pwdId: String, stoken: String, pdirFid: String, cookie: String, page: Int = 1) async throws -> [QuarkShareFile] {
        let url = quarkAPIURLWithStrictQuery("/1/clouddrive/share/sharepage/detail", queryItems: [
            URLQueryItem(name: "__t", value: String(Int(Date().timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "_fetch_banner", value: "1"),
            URLQueryItem(name: "_fetch_total", value: "1"),
            URLQueryItem(name: "_page", value: String(page)),
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
        self.log("[Quark] detail请求诊断 pdirFid=\(pdirFid), stokenLength=\(stoken.count), stokenHasPlus=\(stokenHasPlus), encodedPlus=\(encodedPlus)")
        let (data, response) = try await session.data(for: request)
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? ""
            self.log("[Quark] ❌ detail非JSON status=\(httpStatus), preview=\(preview)")
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? ""
            self.log("[Quark] ❌ detail失败 status=\(httpStatus), code=\(code), message=\(message), preview=\(preview)")
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
            "scene": "link",
            "platform_original": "chrome",
            "nu_distribute": 0
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)

        let respStr = String(data: data, encoding: .utf8) ?? ""
        self.log("[Quark] save响应: \(respStr.prefix(500))")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self.log("[Quark] ❌ 转存响应非JSON")
            throw DriveError.saveFailed
        }

        if let status = json["status"] as? Int, status != 200 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "状态码: \(status)"
            self.log("[Quark] ❌ 转存失败: \(message)")
            throw DriveError.noPlayURL("夸克转存失败: \(message)")
        }

        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? json["msg"] as? String ?? "错误码: \(code)"
            self.log("[Quark] ❌ 转存失败: code=\(code), message=\(message)")
            // 检测容量/配额相关错误，给出更明确的提示
            let lowerMsg = message.lowercased()
            if lowerMsg.contains("空间") || lowerMsg.contains("容量") || lowerMsg.contains("quota")
               || lowerMsg.contains("full") || lowerMsg.contains("insufficient") || lowerMsg.contains("超限") {
                throw DriveError.noPlayURL("夸克容量不足，无法转存此文件。请清理夸克云盘空间后重试")
            }
            throw DriveError.noPlayURL("夸克转存失败: \(message)")
        }

        if let d = json["data"] as? [String: Any] {
            // 保存task_id用于后续轮询
            if let taskId = d["task_id"] as? String {
                quarkLastSaveTaskId = taskId
                self.log("[Quark] 转存任务ID: \(taskId)")
            }
            let taskResp = d["task_resp"] as? [String: Any]
            let taskData = taskResp?["data"] as? [String: Any]
            let saveAs = taskData?["save_as"] as? [String: Any]
            if let ids = saveAs?["save_as_top_fids"] as? [String], !ids.isEmpty {
                self.log("[Quark] ✅ 转存成功，save_as_top_fids: \(ids)")
                // save_as_top_fids 可能返回文件夹ID(如"0")而非文件ID
                if ids.allSatisfy({ $0 == "0" || $0 == folderId }) {
                    self.log("[Quark] ⚠️ save_as_top_fids 返回的是目录ID，尝试按文件名查找实际fid")
                } else {
                    return ids
                }
            }
            if let ids = saveAs?["save_as_select_top_fids"] as? [String], !ids.isEmpty {
                self.log("[Quark] ✅ 转存成功，save_as_select_top_fids: \(ids)")
                if ids.allSatisfy({ $0 == "0" || $0 == folderId }) {
                    self.log("[Quark] ⚠️ save_as_select_top_fids 返回的是目录ID，尝试按文件名查找实际fid")
                } else {
                    return ids
                }
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
            self.log("[Quark] ✅ 转存成功，递归提取 fid: \(recursiveIds)")
            return recursiveIds
        }

        if let existingId = await quarkFindSavedFileId(fileName: file.fileName, folderId: folderId, cookie: cookie) {
            self.log("[Quark] ✅ 转存目录已存在同名文件，使用 fid=\(existingId)")
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

    /// 查找"来自：分享"目录的fid，用于二次查找转存文件
    private func quarkFindShareOriginFolder(cookie: String) async -> String? {
        let url = quarkAPIURL("/1/clouddrive/file/sort")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie)
        let body: [String: Any] = [
            "pdir_fid": "0",
            "sort_by": "updated_at",
            "sort_order": "desc",
            "page": 1,
            "size": 50
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let list = dataObj["list"] as? [[String: Any]] else {
            return nil
        }

        for item in list {
            let name = item["file_name"] as? String ?? item["name"] as? String ?? ""
            if name.contains("来自") && name.contains("分享") {
                if let fid = item["fid"] as? String, !fid.isEmpty { return fid }
                if let fid = item["fid"] as? Int { return String(fid) }
            }
        }
        return nil
    }

    /// 对齐iBox原画抓包：调用 acquire_dl_token 获取加速下载token
    /// 注意：这个接口的Host是 drive-social-api.quark.cn，不是 drive-pc.quark.cn
    private func quarkAcquireDLToken(cookie: String) async throws -> String {
        var components = URLComponents(string: "https://drive-social-api.quark.cn/1/clouddrive/chat/conv/file/acquire_dl_token")!
        components.queryItems = [
            URLQueryItem(name: "pr", value: "ucpro"),
            URLQueryItem(name: "fr", value: "pc"),
            URLQueryItem(name: "sys", value: "darwin"),
            URLQueryItem(name: "ve", value: "3.19.0")
        ]
        guard let url = components.url else {
            throw DriveError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie)
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        let body: [String: Any] = [
            "conversation_id": "300000\(timestamp)",
            "conversation_type": 3,
            "msg_id": "\(timestamp)000"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("夸克 acquire_dl_token 失败：\(message)")
        }
        guard let dataObj = json["data"] as? [String: Any],
              let token = dataObj["token"] as? String, !token.isEmpty else {
            throw DriveError.noPlayURL("夸克 acquire_dl_token 未返回token")
        }
        self.log("[Quark] 获取到加速下载token")
        return token
    }

    private func quarkGetDownloadURL(fileId: String, cookie: String) async throws -> (url: String, fileName: String) {
        // 先获取加速token（对齐iBox原画抓包）
        var dlToken: String? = nil
        do {
            dlToken = try await quarkAcquireDLToken(cookie: cookie)
        } catch {
            self.log("[Quark] ⚠️ acquire_dl_token 失败，继续尝试普通下载：\(error.localizedDescription)")
        }

        let url = quarkAPIURL("/1/clouddrive/file/download")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        quarkSetCommonHeaders(&request, cookie: cookie)
        // 对齐iBox原画抓包：增加 speedup_session 和 token（加速token）
        var body: [String: Any] = [
            "fids": [fileId],
            "speedup_session": ""
        ]
        if let dlToken = dlToken, !dlToken.isEmpty {
            body["token"] = dlToken
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
        let ext = (fileName as NSString).pathExtension.lowercased()
        if downloadURL.isEmpty {
            self.log("[Quark] ⚠️ download_url 为空 (文件: \(fileName), 扩展名: \(ext))，将使用v2/play转码")
        } else {
            self.log("[Quark] 📥 download_url 已获取 (文件: \(fileName), 扩展名: \(ext))")
        }
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

        baiduLog("[Baidu-iBox] 文件列表走 iBox-style 本机路链：wap/init → verify → share页/yunData → gettemplatevariable → share/list")
        recordBaiduRouteDiagnostic(stage: "文件列表", status: "iBox开始", detail: "本机 /wap/init + verify + share页/yunData + gettemplatevariable + share/list(web=1)，不走 Worker")
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

        var mediainfoFallback: PlayResult?
        do {
            mediainfoFallback = try await baiduGetDLNADlinkOnDevice(filePath: item.path, cookie: mergedCookie, source: "ibox-mediainfo-fallback")
            baiduLog("[Baidu-iBox] ✅ mediainfo 探测完成，继续 locatedownload")
        } catch {
            baiduLog("[Baidu-iBox] ⚠️ mediainfo 探测失败，继续 locatedownload：\(error.localizedDescription)")
            recordBaiduRouteDiagnostic(stage: "iBox", status: "mediainfo失败", detail: "path mediainfo 探测失败，继续 locatedownload：\(error.localizedDescription)", fsId: fsId, fileName: item.fileName)
        }
        let refreshed: PlayResult
        do {
            refreshed = try await baiduGetLocatedownloadOnDevice(filePath: item.path, cookie: mergedCookie)
        } catch {
            if let mediainfoFallback {
                baiduLog("[Baidu-iBox] ⚠️ locatedownload 失败，使用 mediainfo dlink 兜底：\(error.localizedDescription)")
                refreshed = mediainfoFallback
            } else {
                throw error
            }
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

    /// 严格对齐 iBox：创建目录 / 转存 / 列目录这些「用户态私域接口」
    /// 必须使用登录态 bdstoken，不能复用分享页 yunData 里的 bdstoken；
    /// 否则百度会判定为越权，统一返回 errno=-6 path:""。
    private func baiduFetchUserBdstokenLocal(cookie: String) async -> String? {
        let savedBdstoken = CloudDriveAuthManager.shared.credential(for: .baidu)?.extra["bdstoken"]

        var components = URLComponents(string: "https://pan.baidu.com/api/gettemplatevariable")!
        components.queryItems = [
            URLQueryItem(name: "clienttype", value: "0"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "fields", value: "[\"bdstoken\",\"token\",\"uk\",\"isdocuser\",\"servertime\"]")
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com/disk/main", forHTTPHeaderField: "Referer")
        if let (data, _) = try? await session.data(for: request),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let errno = json["errno"] as? Int ?? 0
            if let token = baiduDeepString(json, keys: ["bdstoken"]), !token.isEmpty {
                baiduLog("[Baidu-Local] ✅ 取得登录态 bdstoken：\(token.prefix(6))…")
                baiduPersistUserBdstoken(token, mergedCookie: cookie, source: "urlsession-templatevariable")
                return token
            }
            baiduLog("[Baidu-Local] ⚠️ gettemplatevariable 未返回 bdstoken：errno=\(errno), keys=\(json.keys.sorted().joined(separator: ",")), \(baiduJSONStructureSummary(json["result"], label: "result"))")
        }
        // 回退：直接抓 iBox 登录目标页 disk/main 页面里的用户态 bdstoken
        var pageRequest = URLRequest(url: URL(string: "https://pan.baidu.com/disk/main")!)
        pageRequest.timeoutInterval = 12
        pageRequest.setValue(cookie, forHTTPHeaderField: "Cookie")
        pageRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        if let (data, _) = try? await session.data(for: pageRequest),
           let html = String(data: data, encoding: .utf8) {
            if let token = baiduExtractBdstokenFromHTML(html), !token.isEmpty {
                baiduLog("[Baidu-Local] ✅ 从 disk/main 抓到 bdstoken：\(token.prefix(6))…")
                baiduPersistUserBdstoken(token, mergedCookie: cookie, source: "urlsession-disk-main")
                return token
            }
            baiduLog("[Baidu-Local] ⚠️ disk/main 未解析到 bdstoken：htmlSize=\(html.count)")
        }
        if let token = await baiduFetchUserBdstokenViaWebView(cookie: cookie) {
            return token
        }
        if let saved = savedBdstoken, !saved.isEmpty {
            baiduLog("[Baidu-Local] ⚠️ 本次未抓到新 bdstoken，临时回退授权中心保存值：\(saved.prefix(6))…")
            return saved
        }
        baiduLog("[Baidu-Local] ⚠️ 未能抓到登录态 bdstoken")
        return nil
    }

    /// 对齐 iBox 的真实浏览器会话：原生 URLSession 无法生成用户态 bdstoken 时，
    /// 使用 WKWebView 载入 pan.baidu.com/disk/main，并复用 WebView CookieJar 中的登录态。
    private func baiduFetchUserBdstokenViaWebView(cookie: String) async -> String? {
        do {
            let result = try await BaiduWebViewBridge.shared.loadPanPageForBdstoken(cookie: cookie)
            let token = result.bdstoken ?? baiduExtractBdstokenFromHTML(result.html)
            guard let token, !token.isEmpty else {
                baiduLog("[Baidu-Local] ⚠️ WebView disk/main 未解析到 bdstoken：htmlSize=\(result.html.count), cookieHasBDUSS=\(result.cookie.lowercased().contains("bduss=")), cookieHasSTOKEN=\(result.cookie.lowercased().contains("stoken="))")
                return nil
            }
            baiduPersistUserBdstoken(token, mergedCookie: result.cookie, source: "webview-disk-main")
            baiduLog("[Baidu-Local] ✅ WebView 取得登录态 bdstoken：\(token.prefix(6))…")
            return token
        } catch {
            baiduLog("[Baidu-Local] ⚠️ WebView 获取 bdstoken 失败：\(error.localizedDescription)")
            return nil
        }
    }

    private func baiduPersistUserBdstoken(_ token: String, mergedCookie: String, source: String) {
        guard !token.isEmpty,
              var credential = CloudDriveAuthManager.shared.credential(for: .baidu) else { return }
        let cookie = baiduMergeCookieStrings([credential.cookie ?? "", mergedCookie])
        if !cookie.isEmpty {
            credential.cookie = cookie
        }
        credential.extra["bdstoken"] = token
        credential.extra["bdstoken_source"] = source
        credential.updatedAt = Date()
        credential.lastCheckedAt = Date()
        credential.state = .valid
        credential.statusMessage = "百度登录态已补齐 bdstoken"
        CloudDriveAuthManager.shared.saveCredential(credential, syncLegacyToken: false)
    }

    private func baiduExtractBdstokenFromHTML(_ html: String) -> String? {
        let patterns = [
            #"["']bdstoken["']\s*:\s*["']([^"']+)["']"#,
            #"bdstoken\s*=\s*["']([^"']+)["']"#,
            #"bdstoken=([A-Za-z0-9_\-%.]+)"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               match.numberOfRanges >= 2,
               let range = Range(match.range(at: 1), in: html) {
                let token = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { return token.removingPercentEncoding ?? token }
            }
        }
        return nil
    }

    private func baiduJSONStructureSummary(_ value: Any?, label: String) -> String {
        guard let value else { return "\(label)=nil" }
        if let dict = value as? [String: Any] {
            return "\(label)Type=dict,\(label)Keys=\(dict.keys.sorted().joined(separator: ","))"
        }
        if let array = value as? [Any] {
            let firstType: String
            if let first = array.first {
                firstType = String(describing: Swift.type(of: first))
            } else {
                firstType = "empty"
            }
            return "\(label)Type=array,\(label)Count=\(array.count),first=\(firstType)"
        }
        if let text = value as? String {
            return "\(label)Type=string,\(label)Length=\(text.count)"
        }
        return "\(label)Type=\(String(describing: Swift.type(of: value)))"
    }

    private func baiduDeepString(_ value: Any, keys: Set<String>) -> String? {
        if let dict = value as? [String: Any] {
            for (key, raw) in dict where keys.contains(key.lowercased()) {
                if let text = raw as? String, !text.isEmpty { return text }
                if let number = raw as? NSNumber { return number.stringValue }
            }
            for raw in dict.values {
                if let found = baiduDeepString(raw, keys: keys), !found.isEmpty { return found }
                if let text = raw as? String,
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data),
                   let found = baiduDeepString(json, keys: keys),
                   !found.isEmpty {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for raw in array {
                if let found = baiduDeepString(raw, keys: keys), !found.isEmpty { return found }
            }
        }
        return nil
    }

    private func baiduEnsureVboxFolderLocal(cookie: String, bdstoken: String, referer: String) async throws {
        let webUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
        if try await baiduCanListTransferDir(cookie: cookie, bdstoken: bdstoken, referer: referer, userAgent: webUA) {
            return
        }

        var lastResponse = ""
        for folder in [Self.baiduIBoxTransferDir] {
            var components = URLComponents(string: "https://pan.baidu.com/api/create")!
            components.queryItems = [
                URLQueryItem(name: "a", value: "commit"),
                URLQueryItem(name: "bdstoken", value: bdstoken),
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
            request.setValue(webUA, forHTTPHeaderField: "User-Agent")
            request.setValue(referer, forHTTPHeaderField: "Referer")
            request.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            // 严格对齐 iBox 抓包：必须带 size=0、method=post，block_list 的 [] 也要 URL 编码
            let encodedPath = folder.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? folder
            let encodedBlockList = "[]".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "%5B%5D"
            request.httpBody = "path=\(encodedPath)&size=0&isdir=1&block_list=\(encodedBlockList)&method=post".data(using: .utf8)

            let (data, _) = try await session.data(for: request)
            lastResponse = String(data: data.prefix(220), encoding: .utf8) ?? ""
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errno = json["errno"] as? Int,
               errno == 0 || errno == -8 {
                continue
            }
            baiduLog("[Baidu-Local] ⚠️ api/create \(folder) 响应：\(lastResponse)")
            try await baiduCreateFolderByFileManager(path: folder, cookie: cookie, bdstoken: bdstoken, referer: referer, userAgent: webUA)
            if lastResponse.contains(#""errno":-6"#) || lastResponse.contains(#""errno": -6"#) {
                let ok = await baiduCreateFolderViaWebView(path: folder, cookie: cookie, bdstoken: bdstoken)
                if ok {
                    baiduLog("[Baidu-Local] ✅ WebView XHR create \(folder) 成功或已存在")
                }
            }
        }

        let canListByURLSession = try await baiduCanListTransferDir(cookie: cookie, bdstoken: bdstoken, referer: referer, userAgent: webUA)
        let canList: Bool
        if canListByURLSession {
            canList = true
        } else {
            canList = await baiduCanListTransferDirViaWebView(cookie: cookie, bdstoken: bdstoken)
        }
        guard canList else {
            throw DriveError.noPlayURL("百度 vbox 转存目录创建失败：\(lastResponse)")
        }
    }

    private func baiduCreateFolderViaWebView(path: String, cookie: String, bdstoken: String) async -> Bool {
        do {
            let page = try await BaiduWebViewBridge.shared.loadPanPageForBdstoken(cookie: cookie, timeout: 12, resetCookies: true)
            let effectiveBdstoken = page.bdstoken ?? bdstoken
            var components = URLComponents(string: "https://pan.baidu.com/api/create")!
            components.queryItems = [
                URLQueryItem(name: "a", value: "commit"),
                URLQueryItem(name: "bdstoken", value: effectiveBdstoken),
                URLQueryItem(name: "channel", value: "chunlei"),
                URLQueryItem(name: "web", value: "1"),
                URLQueryItem(name: "app_id", value: "250528"),
                URLQueryItem(name: "clienttype", value: "0")
            ]
            let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
            let encodedBlockList = "[]".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "%5B%5D"
            let body = "path=\(encodedPath)&size=0&isdir=1&block_list=\(encodedBlockList)&method=post"
            let result = try await BaiduWebViewBridge.shared.request(
                url: components.url!.absoluteString,
                method: "POST",
                headers: [
                    "Content-Type": "application/x-www-form-urlencoded",
                    "X-Requested-With": "XMLHttpRequest"
                ],
                body: body,
                timeout: 12
            )
            let preview = String(data: result.data.prefix(220), encoding: .utf8) ?? ""
            guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
                  let errno = json["errno"] as? Int else {
                baiduLog("[Baidu-Local] ⚠️ WebView XHR create \(path) 返回不可解析：\(preview)")
                return false
            }
            if errno == 0 || errno == -8 {
                return true
            }
            baiduLog("[Baidu-Local] ⚠️ WebView XHR create \(path) 响应：\(preview)")
            return false
        } catch {
            baiduLog("[Baidu-Local] ⚠️ WebView XHR create \(path) 异常：\(error.localizedDescription)")
            return false
        }
    }

    private func baiduCreateFolderByFileManager(path: String, cookie: String, bdstoken: String, referer: String, userAgent: String) async throws {
        var components = URLComponents(string: "https://pan.baidu.com/api/filemanager")!
        components.queryItems = [
            URLQueryItem(name: "opera", value: "create"),
            URLQueryItem(name: "bdstoken", value: bdstoken),
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
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        request.httpBody = "path=\(encodedPath)&isdir=1&block_list=%5B%5D".data(using: .utf8)

        let (data, _) = try await session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errno = json["errno"] as? Int,
              errno == 0 || errno == -8 else {
            let preview = String(data: data.prefix(220), encoding: .utf8) ?? ""
            baiduLog("[Baidu-Local] ⚠️ filemanager create \(path) 响应：\(preview)")
            return
        }
        baiduLog("[Baidu-Local] ✅ filemanager create \(path) 成功或已存在")
    }

    private func baiduCanListTransferDir(cookie: String, bdstoken: String, referer: String, userAgent: String) async throws -> Bool {
        var components = URLComponents(string: "https://pan.baidu.com/api/list")!
        components.queryItems = [
            URLQueryItem(name: "dir", value: Self.baiduIBoxTransferDir),
            URLQueryItem(name: "order", value: "time"),
            URLQueryItem(name: "desc", value: "1"),
            URLQueryItem(name: "num", value: "1"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "bdstoken", value: bdstoken),
            URLQueryItem(name: "channel", value: "chunlei"),
            URLQueryItem(name: "web", value: "1"),
            URLQueryItem(name: "app_id", value: "250528"),
            URLQueryItem(name: "clienttype", value: "0")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 12
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, _) = try await session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let errno = json["errno"] as? Int ?? 0
        if errno == 0 {
            baiduLog("[Baidu-Local] ✅ vbox 转存目录可访问：\(Self.baiduIBoxTransferDir)")
            return true
        }
        baiduLog("[Baidu-Local] ⚠️ vbox 转存目录不可访问：errno=\(errno)")
        return false
    }

    private func baiduCanListTransferDirViaWebView(cookie: String, bdstoken: String) async -> Bool {
        do {
            let page = try await BaiduWebViewBridge.shared.loadPanPageForBdstoken(cookie: cookie, timeout: 12, resetCookies: false)
            let effectiveBdstoken = page.bdstoken ?? bdstoken
            var components = URLComponents(string: "https://pan.baidu.com/api/list")!
            components.queryItems = [
                URLQueryItem(name: "dir", value: Self.baiduIBoxTransferDir),
                URLQueryItem(name: "order", value: "time"),
                URLQueryItem(name: "desc", value: "1"),
                URLQueryItem(name: "num", value: "1"),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "bdstoken", value: effectiveBdstoken),
                URLQueryItem(name: "channel", value: "chunlei"),
                URLQueryItem(name: "web", value: "1"),
                URLQueryItem(name: "app_id", value: "250528"),
                URLQueryItem(name: "clienttype", value: "0")
            ]
            let result = try await BaiduWebViewBridge.shared.request(url: components.url!.absoluteString, timeout: 12)
            guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
                return false
            }
            let errno = json["errno"] as? Int ?? 0
            if errno == 0 {
                baiduLog("[Baidu-Local] ✅ WebView XHR vbox 转存目录可访问：\(Self.baiduIBoxTransferDir)")
                return true
            }
            baiduLog("[Baidu-Local] ⚠️ WebView XHR vbox 转存目录不可访问：errno=\(errno)")
            return false
        } catch {
            baiduLog("[Baidu-Local] ⚠️ WebView XHR vbox 目录检查异常：\(error.localizedDescription)")
            return false
        }
    }

    private func baiduFindExistingVboxPath(fileName: String, cookie: String) async throws -> String? {
        func matchedPath(from json: [String: Any]) -> String? {
            let root = (json["data"] as? [String: Any]) ?? json
            let list = root["list"] as? [[String: Any]]
                ?? root["file_list"] as? [[String: Any]]
                ?? root["records"] as? [[String: Any]]
                ?? []
            let normalizedTarget = fileName.split(separator: "/").last.map(String.init) ?? fileName
            let targetBase = (normalizedTarget as NSString).deletingPathExtension
            let targetExt = (normalizedTarget as NSString).pathExtension
            for item in list {
                let name = item["server_filename"] as? String
                    ?? item["filename"] as? String
                    ?? item["name"] as? String
                    ?? ""
                let nameBase = (name as NSString).deletingPathExtension
                let nameExt = (name as NSString).pathExtension
                if name == normalizedTarget || (!targetBase.isEmpty && nameBase.hasPrefix(targetBase) && (targetExt.isEmpty || nameExt == targetExt)) {
                    return item["path"] as? String ?? "\(Self.baiduIBoxTransferDir)/\(normalizedTarget)"
                }
            }
            return nil
        }

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
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return await baiduFindExistingVboxPathViaWebView(fileName: fileName, cookie: cookie)
        }

        let errno = json["errno"] as? Int ?? 0
        if errno != 0 {
            baiduLog("[Baidu-Local] ⚠️ URLSession 查找 /vbox 文件失败：errno=\(errno)，改用 WebView XHR")
            return await baiduFindExistingVboxPathViaWebView(fileName: fileName, cookie: cookie)
        }
        if let path = matchedPath(from: json) {
            return path
        }
        return await baiduFindExistingVboxPathViaWebView(fileName: fileName, cookie: cookie)
    }

    private func baiduFindExistingVboxPathViaWebView(fileName: String, cookie: String) async -> String? {
        do {
            _ = try await BaiduWebViewBridge.shared.loadPanPageForBdstoken(cookie: cookie, timeout: 12, resetCookies: false)
            var components = URLComponents(string: "https://pan.baidu.com/api/list")!
            components.queryItems = [
                URLQueryItem(name: "bdstoken", value: ""),
                URLQueryItem(name: "channel", value: "chunlei"),
                URLQueryItem(name: "web", value: "1"),
                URLQueryItem(name: "app_id", value: "250528"),
                URLQueryItem(name: "clienttype", value: "0")
            ]
            let encodedDir = Self.baiduIBoxTransferDir.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Self.baiduIBoxTransferDir
            let body = "dir=\(encodedDir)&order=time&desc=1&num=200&page=1"
            let result = try await BaiduWebViewBridge.shared.request(
                url: components.url!.absoluteString,
                method: "POST",
                headers: ["Content-Type": "application/x-www-form-urlencoded"],
                body: body,
                timeout: 12
            )
            guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
                return nil
            }
            let errno = json["errno"] as? Int ?? 0
            if errno != 0 {
                baiduLog("[Baidu-Local] ⚠️ WebView XHR 查找 /vbox 文件失败：errno=\(errno)")
                return nil
            }
            let root = (json["data"] as? [String: Any]) ?? json
            let list = root["list"] as? [[String: Any]]
                ?? root["file_list"] as? [[String: Any]]
                ?? root["records"] as? [[String: Any]]
                ?? []
            let normalizedTarget = fileName.split(separator: "/").last.map(String.init) ?? fileName
            let targetBase = (normalizedTarget as NSString).deletingPathExtension
            let targetExt = (normalizedTarget as NSString).pathExtension
            for item in list {
                let name = item["server_filename"] as? String
                    ?? item["filename"] as? String
                    ?? item["name"] as? String
                    ?? ""
                let nameBase = (name as NSString).deletingPathExtension
                let nameExt = (name as NSString).pathExtension
                if name == normalizedTarget || (!targetBase.isEmpty && nameBase.hasPrefix(targetBase) && (targetExt.isEmpty || nameExt == targetExt)) {
                    let path = item["path"] as? String ?? "\(Self.baiduIBoxTransferDir)/\(normalizedTarget)"
                    baiduLog("[Baidu-Local] ✅ WebView XHR 查到 /vbox 文件：\(path)")
                    return path
                }
            }
            return nil
        } catch {
            baiduLog("[Baidu-Local] ⚠️ WebView XHR 查找 /vbox 文件异常：\(error.localizedDescription)")
            return nil
        }
    }

    private func baiduWaitForTransferredPath(fileName: String, cookie: String, preferredPath: String? = nil) async throws -> String {
        if let preferredPath, !preferredPath.isEmpty {
            baiduLog("[Baidu-Local] 转存返回目标 path：\(preferredPath)")
            return preferredPath
        }

        var lastPath: String?
        for attempt in 1...8 {
            if attempt > 1 {
                try? await Task.sleep(nanoseconds: UInt64(650_000_000 * min(attempt, 4)))
            }
            if let path = try await baiduFindExistingVboxPath(fileName: fileName, cookie: cookie) {
                baiduLog("[Baidu-Local] ✅ 转存落盘确认成功：attempt=\(attempt), path=\(path)")
                return path
            }
            lastPath = "\(Self.baiduIBoxTransferDir)/\(fileName.split(separator: "/").last.map(String.init) ?? fileName)"
            baiduLog("[Baidu-Local] ⏳ 等待转存落盘：attempt=\(attempt)")
        }

        throw DriveError.noPlayURL("百度转存任务未确认落盘：\(lastPath ?? fileName)")
    }

    private func baiduTransferFileOnDevice(
        shareURL: String,
        shareid: String,
        shareUk: String,
        bdstoken: String,
        randsk: String?,
        fsId: String,
        fileName: String,
        cookie: String,
        accountCookie: String,
        referer: String
    ) async throws -> String {
        var transferCookie = cookie
        if let refreshed = await baiduRefreshTransferSekey(shareURL: shareURL, accountCookie: accountCookie, existingCookie: cookie) {
            transferCookie = refreshed
        }
        // 严格对齐 iBox 抓包：share/transfer 的 sekey 优先使用 Cookie 里的 BDCLND 原始值。
        // BDCLND 通常已经是百分号编码形态，不能再交给 URLQueryItem 二次编码，否则百度会认为分享信息不完整。
        let rawSekey = baiduCookieValue(transferCookie, named: "BDCLND") ?? randsk ?? ""
        var query = [
            "shareid=\(baiduQueryEncoded(shareid))",
            "from=\(baiduQueryEncoded(shareUk))",
            "channel=chunlei",
            "web=1",
            "app_id=250528",
            "clienttype=0",
            "bdstoken=\(baiduQueryEncoded(bdstoken))"
        ]
        if !rawSekey.isEmpty {
            let encodedSekey = rawSekey.contains("%") ? rawSekey : baiduQueryEncoded(rawSekey)
            query.append("sekey=\(encodedSekey)")
        }
        guard let transferURL = URL(string: "https://pan.baidu.com/share/transfer?\(query.joined(separator: "&"))") else {
            throw DriveError.invalidShareURL
        }

        var request = URLRequest(url: transferURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue(transferCookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let transferPath = Self.baiduIBoxTransferDir.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Self.baiduIBoxTransferDir
        // 恢复 3.232 已验证可播放行为：fsidlist 必须 URL 编码，并使用百度异步转存队列。
        let encodedFsidList = "[\(fsId)]".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "%5B\(fsId)%5D"
        let transferBody = "fsidlist=\(encodedFsidList)&path=\(transferPath)&async=1&ondup=newcopy"
        request.httpBody = transferBody.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let path = try? await baiduTransferFileViaWebView(
                transferURL: transferURL,
                transferCookie: transferCookie,
                transferBody: transferBody,
                fileName: fileName,
                accountCookie: accountCookie
            ) {
                return path
            }
            throw DriveError.noPlayURL("百度本机转存 HTTP \(status)")
        }

        let errno = json["errno"] as? Int ?? -1
        if errno != 0 {
            let msg = baiduErrorMessage(errno: errno, fallback: json["errmsg"] as? String ?? json["show_msg"] as? String)
            baiduLog("[Baidu-Local] ❌ 本机转存失败：\(msg), hasBDCLND=\(transferCookie.lowercased().contains("bdclnd=")), hasBDUSS=\(transferCookie.lowercased().contains("bduss=")), hasSTOKEN=\(transferCookie.lowercased().contains("stoken="))")
            if let path = try? await baiduTransferFileViaWebView(
                transferURL: transferURL,
                transferCookie: transferCookie,
                transferBody: transferBody,
                fileName: fileName,
                accountCookie: accountCookie
            ) {
                return path
            }
            throw DriveError.noPlayURL("百度本机转存失败：\(msg)")
        }

        let taskID = json["task_id"] as? String
            ?? (json["extra"] as? [String: Any])?["task_id"] as? String
            ?? (json["request_id"] as? NSNumber)?.stringValue
        if let taskID, !taskID.isEmpty {
            baiduLog("[Baidu-Local] 转存返回任务标识：\(taskID)")
        }

        if let extra = json["extra"] as? [String: Any],
           let list = extra["list"] as? [[String: Any]],
           let first = list.first,
           let to = first["to"] as? String,
           !to.isEmpty {
            return to
        }

        let normalizedName = fileName.split(separator: "/").last.map(String.init) ?? fileName
        return try await baiduWaitForTransferredPath(fileName: normalizedName, cookie: accountCookie)
    }

    private func baiduTransferFileViaWebView(
        transferURL: URL,
        transferCookie: String,
        transferBody: String,
        fileName: String,
        accountCookie: String
    ) async throws -> String {
        _ = try await BaiduWebViewBridge.shared.loadPanPageForBdstoken(cookie: transferCookie, timeout: 12, resetCookies: false)
        let result = try await BaiduWebViewBridge.shared.request(
            url: transferURL.absoluteString,
            method: "POST",
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "X-Requested-With": "XMLHttpRequest"
            ],
            body: transferBody,
            timeout: 25
        )
        guard let json = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            let preview = String(data: result.data.prefix(220), encoding: .utf8) ?? ""
            baiduLog("[Baidu-Local] ⚠️ WebView XHR 转存返回不可解析：\(preview)")
            throw DriveError.noPlayURL("百度 WebView 转存返回不可解析")
        }
        let errno = json["errno"] as? Int ?? -1
        guard errno == 0 else {
            let msg = baiduErrorMessage(errno: errno, fallback: json["errmsg"] as? String ?? json["show_msg"] as? String)
            baiduLog("[Baidu-Local] ⚠️ WebView XHR 转存失败：\(msg)")
            throw DriveError.noPlayURL("百度 WebView 转存失败：\(msg)")
        }
        baiduLog("[Baidu-Local] ✅ WebView XHR 转存请求成功")
        if let taskID = json["task_id"] as? String
            ?? (json["extra"] as? [String: Any])?["task_id"] as? String
            ?? (json["request_id"] as? NSNumber)?.stringValue,
           !taskID.isEmpty {
            baiduLog("[Baidu-Local] WebView XHR 转存任务标识：\(taskID)")
        }
        if let extra = json["extra"] as? [String: Any],
           let list = extra["list"] as? [[String: Any]],
           let first = list.first,
           let to = first["to"] as? String,
           !to.isEmpty {
            return to
        }
        let normalizedName = fileName.split(separator: "/").last.map(String.init) ?? fileName
        return try await baiduWaitForTransferredPath(fileName: normalizedName, cookie: accountCookie)
    }

    /// share/list 可以使用匿名分享态验证，但 share/transfer 属于账号转存动作。
    /// 百度会校验 BDCLND/sekey 是否绑定到当前账号会话；否则可能返回 errno=200025。
    private func baiduRefreshTransferSekey(shareURL: String, accountCookie: String, existingCookie: String) async -> String? {
        guard let pwd = extractBaiduPwd(from: shareURL), !pwd.isEmpty,
              let surl = try? baiduExtractSurl(from: shareURL) else {
            return nil
        }
        let shortSurl = baiduShortSurl(surl)
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let encodedPwd = pwd.addingPercentEncoding(withAllowedCharacters: allowed) ?? pwd
        let verifyURL = "https://pan.baidu.com/share/verify?t=\(Int(Date().timeIntervalSince1970 * 1000))&surl=\(shortSurl)&channel=chunlei&web=1&app_id=250528&bdstoken=&clienttype=0"
        guard let url = URL(string: verifyURL) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 18
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(accountCookie, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
        request.setValue("https://pan.baidu.com/s/1\(shortSurl)", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-Hans-001;q=1.0", forHTTPHeaderField: "Accept-Language")
        request.httpBody = "pwd=\(encodedPwd)&vcode=&vcode_str=&channel=chunlei&web=1&app_id=250528&clienttype=0&bdstoken=".data(using: .utf8)
        do {
            let (data, response) = try await session.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                let preview = String(data: data.prefix(160), encoding: .utf8) ?? ""
                baiduLog("[Baidu-Local] ⚠️ 账号态 verify 返回非 JSON：\(preview)")
                return nil
            }
            let errno = json["errno"] as? Int ?? -1
            guard errno == 0 else {
                let msg = baiduErrorMessage(errno: errno, fallback: json["errmsg"] as? String ?? json["show_msg"] as? String)
                baiduLog("[Baidu-Local] ⚠️ 账号态 verify 失败：\(msg)")
                return nil
            }
            var merged = baiduMergeCookieStrings([existingCookie, accountCookie])
            if let sc = (response as? HTTPURLResponse)?.allHeaderFields["Set-Cookie"] as? String {
                merged = baiduMergeCookieStrings([merged, sc])
            }
            if let rawRandsk = json["randsk"] as? String, !rawRandsk.isEmpty {
                let decodedRandsk = rawRandsk.removingPercentEncoding ?? rawRandsk
                merged = baiduMergeCookieStrings([merged, "BDCLND=\(rawRandsk); randsk=\(decodedRandsk)"])
                baiduLog("[Baidu-Local] ✅ 账号态 verify 成功，刷新 share/transfer sekey")
            }
            return merged
        } catch {
            baiduLog("[Baidu-Local] ⚠️ 账号态 verify 异常：\(error.localizedDescription)")
            return nil
        }
    }

    private func baiduQueryEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
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

    private func baiduErrorMessage(errno: Int, fallback: String? = nil) -> String {
        switch errno {
        case 0:
            return "成功"
        case -9:
            return "提取码错误"
        case 200025:
            return "分享验证态未绑定当前账号，请重新验证后转存"
        case -8:
            return "目标目录或文件已存在"
        case -7, -10:
            return "账号登录态已过期，请重新扫码登录"
        case -6:
            return "身份验证失败，请重新登录百度网盘"
        case -4, 4:
            return "需要图形验证码或安全验证"
        case 2:
            return "参数错误或分享信息不完整"
        case 5:
            return "分享链接不存在或已失效"
        case 10:
            return "分享内容不存在或已被删除"
        case 12:
            return "分享内容违规或不可访问"
        case 105:
            return "百度风控限制，需要在网页完成验证后重试"
        case 110:
            return "分享文件不可转存"
        case 111:
            return "转存数量或目录限制"
        case 115:
            return "该文件禁止转存或下载"
        default:
            if let fallback, !fallback.isEmpty { return "\(fallback) (errno=\(errno))" }
            return "errno=\(errno)"
        }
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
        let msg = baiduErrorMessage(errno: errno, fallback: json["errmsg"] as? String ?? json["show_msg"] as? String ?? json["msg"] as? String)
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
            let msg = baiduErrorMessage(errno: errno, fallback: json["errmsg"] as? String ?? json["show_msg"] as? String ?? json["msg"] as? String)
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
        let ignoredAttributes: Set<String> = ["expires", "path", "domain", "max-age", "secure", "httponly", "samesite"]
        var keys: [String] = []
        var values: [String: (name: String, value: String)] = [:]
        for cookie in cookies where !cookie.isEmpty {
            let normalized = cookie
                .replacingOccurrences(of: #",\s*([A-Za-z_][A-Za-z0-9_\-]*)="#, with: ";\n$1=", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: ";")
            for part in normalized.split(separator: ";") {
                let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = item.firstIndex(of: "=") else { continue }
                let name = String(item[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(item[item.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty else { continue }
                let key = name.lowercased()
                guard !ignoredAttributes.contains(key) else { continue }
                if values[key] == nil { keys.append(key) }
                values[key] = (name, value)
            }
        }
        return keys.compactMap { key in
            guard let item = values[key] else { return nil }
            return "\(item.name)=\(item.value)"
        }.joined(separator: "; ")
    }

    /// 治理隐患 3：私域接口（gettemplatevariable / api/create / filemanager / api/list）
    /// 只允许携带账号态 Cookie；从入参 cookie 中剔除分享态字段（BDCLND / BDCLND_BFESS 等），
    /// 避免历史合并产物把分享态混入用户网盘私域请求，导致 errno=-6/-9。
    private func baiduPureAccountCookie(_ cookie: String) -> String {
        guard !cookie.isEmpty else { return cookie }
        let dropList: Set<String> = [
            "bdclnd", "bdclnd_bfess",
            "share_pwd", "share_pwd_bfess"
        ]
        let merged = baiduMergeCookieStrings([cookie])
        let parts = merged.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let filtered: [String] = parts.compactMap { item in
            guard let eq = item.firstIndex(of: "=") else { return nil }
            let name = item[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            return dropList.contains(name) ? nil : item
        }
        return filtered.joined(separator: "; ")
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
    /// wap/init → verify → share页/yunData → gettemplatevariable → share/list → transfer → api/list → mediainfo/locatedownload。
    /// 失败时直接向调用方抛出错误，不再回落 Worker 或旧分享直链路。
    func resolveBaiduPlayURLViaMainRoute(
        shareURL: String,
        bduss: String,
        fsId: String,
        fileName hintFileName: String? = nil,
        pcsCookie: String = ""
    ) async throws -> PlayResult {
        // 提前触发兜底清理：无论缓存命中与否，都先清理 /vbox 下超过 2 小时的旧文件
        let parsed = parseBaiduToken(bduss)
        let webCookie = parsed.cookie
        let pcs = normalizeBaiduPCSCookie(pcsCookie)
        let earlyCleanupCookie = baiduMergeCookieStrings([webCookie, pcs])
        let earlyPureCookie = baiduPureAccountCookie(earlyCleanupCookie)
        baiduLog("[Baidu-Cleanup] 🔧 早期清理触发器已启动，准备获取 bdstoken...")
        Task { [weak self] in
            baiduLog("[Baidu-Cleanup] 🔧 开始获取 bdstoken，cookie 中 BDUSS=\(baiduCookieValue(earlyPureCookie, named: "BDUSS")?.prefix(8) ?? "nil")…")
            let token = await self?.baiduFetchUserBdstokenLocal(cookie: earlyPureCookie) ?? ""
            baiduLog("[Baidu-Cleanup] 🔧 bdstoken 获取结果：\(token.isEmpty ? "失败（空）" : "成功 \(token.prefix(8))…")")
            if !token.isEmpty {
                self?.baiduCleanupOldTransferFiles(cookie: earlyPureCookie, bdstoken: token)
            } else {
                baiduLog("[Baidu-Cleanup] ❌ bdstoken 为空，清理未执行")
            }
        }

        let cacheKey = baiduMainRouteCacheKey(shareURL: shareURL, fsId: fsId, bduss: bduss, pcsCookie: pcsCookie)
        if let cached = baiduCachedPlayResult(for: cacheKey) {
            baiduLog("[Baidu-MainRoute] ✅ 命中主路链播放缓存：fsId=\(fsId)")
            recordBaiduRouteDiagnostic(stage: "主路链缓存", status: "命中", detail: "命中主路链 dlink 缓存", fsId: fsId, fileName: hintFileName)
            return cached
        }

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
        recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "开始", detail: "wap/init → verify → share页/yunData → gettemplatevariable → share/list → transfer → api/list → locatedownload → 本地代理", fsId: fsId, fileName: hintFileName)

        let pwd = extractBaiduPwd(from: shareURL)
        let context = try await baiduExtractShareMeta(shareURL: shareURL, cookie: webCookie, returnAll: true)
        let matched = context.files.first { $0.fsId == fsId }
            ?? context.files.first { $0.fsId.trimmingCharacters(in: .whitespacesAndNewlines) == fsId.trimmingCharacters(in: .whitespacesAndNewlines) }
        let selected: BaiduFileItem?
        if let matched, baiduIsPlayableVideoFileName(matched.name) {
            selected = matched
        } else if let matched {
            let fallback = context.files.first { baiduIsPlayableVideoFileName($0.name) }
            if let fallback {
                baiduLog("[Baidu-iBoxRoute] ⚠️ fsId 命中非视频文件：\(matched.name)，自动切换到视频：\(fallback.name)")
                recordBaiduRouteDiagnostic(stage: "主路链", status: "跳过非视频", detail: "fsId 指向 \(matched.name)，已切换到 \(fallback.name)", fsId: fsId, fileName: matched.name)
            }
            selected = fallback
        } else {
            selected = context.files.first { baiduIsPlayableVideoFileName($0.name) }
        }
        guard let selected else {
            recordBaiduRouteDiagnostic(stage: "主路链", status: "文件未找到", detail: "分享列表未找到可播放视频，pwd=\((pwd ?? "").isEmpty ? "无" : "有")", fsId: fsId, fileName: hintFileName)
            throw DriveError.noPlayURL("主路链未找到可播放视频")
        }

        let accountCookie = baiduMergeCookieStrings([webCookie, pcs])
        let pureAccountCookie = baiduPureAccountCookie(accountCookie)
        let mergedCookie = baiduMergeCookieStrings([context.cookie, accountCookie])
        guard !mergedCookie.isEmpty else {
            recordBaiduRouteDiagnostic(stage: "主路链", status: "Cookie缺失", detail: "无法合并 BDUSS/STOKEN Cookie", fsId: fsId, fileName: selected.name)
            throw DriveError.noPlayURL("主路链缺少百度 Cookie")
        }

        do {
            // 严格对齐 iBox：转存/创建/列目录用登录态 bdstoken；分享页 bdstoken 在私域接口会被判越权 errno=-6。
            // 创建目录/列用户网盘目录只能用账号 Cookie；share/transfer 再使用账号 Cookie + BDCLND 的混合 Cookie。
            guard let userBdstoken = await baiduFetchUserBdstokenLocal(cookie: pureAccountCookie),
                  !userBdstoken.isEmpty else {
                let message = "百度登录态正常，但未取得用户态 bdstoken，无法创建 vbox 转存目录"
                baiduLog("[Baidu-Local] ❌ \(message)")
                recordBaiduRouteDiagnostic(stage: "主路链", status: "缺少用户态bdstoken", detail: message, fsId: fsId, fileName: selected.name)
                throw DriveError.noPlayURL(message)
            }
            try await baiduEnsureVboxFolderLocal(cookie: pureAccountCookie, bdstoken: userBdstoken, referer: "https://pan.baidu.com/disk/main")
            let existingPath = try await baiduFindExistingVboxPath(fileName: selected.name, cookie: pureAccountCookie)
            let filePath: String
            let sourcePrefix: String
            if let existingPath {
                filePath = existingPath
                sourcePrefix = "main-existing"
                baiduLog("[Baidu-iBoxRoute] ✅ \(Self.baiduIBoxTransferDir) 命中已转存文件：\(filePath)")
                recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "path命中", detail: "命中 \(Self.baiduIBoxTransferDir) 已转存文件：\(filePath)", fsId: fsId, fileName: selected.name)
            } else {
                filePath = try await baiduTransferFileOnDevice(
                    shareURL: shareURL,
                    shareid: context.shareid,
                    shareUk: context.shareUk,
                    bdstoken: userBdstoken,
                    randsk: context.randsk,
                    fsId: selected.fsId,
                    fileName: selected.name,
                    cookie: mergedCookie,
                    accountCookie: pureAccountCookie,
                    referer: shareURL
                )
                sourcePrefix = "main-transfer"
                baiduLog("[Baidu-iBoxRoute] ✅ 本机转存完成：\(filePath)")
                recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "转存成功", detail: "已转存到：\(filePath)", fsId: fsId, fileName: selected.name)
                // 转存成功后立即调度 1 小时后清理（不等播放成功，避免播放失败留下孤儿文件）
                scheduleCleanup(drive: .baidu, fileIds: [filePath], token: pureAccountCookie, delay: 60 * 60)
            }

            var mediainfoFallback: PlayResult?
            do {
                mediainfoFallback = try await baiduGetDLNADlinkOnDevice(filePath: filePath, cookie: mergedCookie, source: "\(sourcePrefix)-mediainfo")
                baiduLog("[Baidu-iBoxRoute] ✅ mediainfo 探测完成，继续 locatedownload")
            } catch {
                baiduLog("[Baidu-iBoxRoute] ⚠️ mediainfo 探测失败，继续 locatedownload：\(error.localizedDescription)")
                recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "mediainfo失败", detail: "继续 locatedownload：\(error.localizedDescription)", fsId: fsId, fileName: selected.name)
            }
            let rawResult: PlayResult
            let source: String
            do {
                rawResult = try await baiduGetLocatedownloadOnDevice(filePath: filePath, cookie: mergedCookie, source: "\(sourcePrefix)-locatedownload")
                source = "\(sourcePrefix)-locatedownload"
            } catch {
                if let mediainfoFallback {
                    baiduLog("[Baidu-iBoxRoute] ⚠️ locatedownload 失败，使用 mediainfo dlink 兜底：\(error.localizedDescription)")
                    recordBaiduRouteDiagnostic(stage: "iBox主路链", status: "locatedownload失败", detail: "使用 mediainfo dlink 兜底：\(error.localizedDescription)", fsId: fsId, fileName: selected.name)
                    rawResult = mediainfoFallback
                    source = "\(sourcePrefix)-mediainfo-fallback"
                } else {
                    throw error
                }
            }

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

    private func baiduExtractShareMeta(shareURL: String, cookie: String, returnAll: Bool = false) async throws -> (shareid: String, shareUk: String, bdstoken: String, surl: String, cookie: String, files: [BaiduFileItem], randsk: String) {
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
        if !returnAll, let cached = baiduCachedShareContext(for: contextKey, currentPwd: pwd) {
            baiduLog("[Baidu-ShareContext] ✅ 命中分享上下文缓存：source=\(cached.source), files=\(cached.files.count)")
            recordBaiduRouteDiagnostic(stage: "分享上下文", status: "缓存命中", detail: "命中 ShareContext：source=\(cached.source), files=\(cached.files.count)")
            return (cached.shareid, cached.shareUk, cached.bdstoken ?? "", cached.surl, cached.cookie, cached.files, cached.randsk ?? "")
        } else if returnAll {
            baiduLog("[Baidu-ShareContext] iBox 严格模式：跳过 ShareContext 缓存，重新验证分享上下文")
        }

        do {
            let shortSurl = baiduShortSurl(surl)
            // 按 iBox 抓包：分享验证与 share/list 使用 Mac Chrome UA，不是 iOS Safari UA。
            let webUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"
            let initURL = "https://pan.baidu.com/wap/init?surl=\(shortSurl)"
            let desktopShareURL = "https://pan.baidu.com/s/1\(shortSurl)"
            var iBoxCookie = cookie
            var shareid = ""
            var shareUk = ""
            var bdstoken = ""
            var shareSign = ""
            var shareTimestamp = ""
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

            func queryEncoded(_ value: String) -> String {
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "&+=?#/")
                return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            }

            func iBoxQueryEncoded(_ value: String, keepSlash: Bool = true) -> String {
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "&+=?#")
                if !keepSlash { allowed.remove(charactersIn: "/") }
                return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            }

            func cookieForShareList(_ cookie: String, includeAccount: Bool) -> String {
                var dropNames: Set<String> = ["stoken", "stoken_bfess", "ptoken", "ptoken_bfess", "passid", "ubi_bfess", "randsk"]
                if !includeAccount {
                    // iBox 抓包：root-shorturl 阶段不能带 BDUSS，只带 BAIDUID/PANPSC/BDCLND 这一类分享态 Cookie。
                    dropNames.formUnion(["bduss", "bduss_bfess"])
                }
                return cookie
                    .split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { part in
                        guard let name = part.split(separator: "=", maxSplits: 1).first?.lowercased() else { return false }
                        return !dropNames.contains(String(name))
                    }
                    .joined(separator: "; ")
            }

            func isDirectory(_ item: [String: Any]) -> Bool {
                let value = stringValue(item["isdir"])
                return value == "1" || value.lowercased() == "true"
            }

            func parsePlayableFiles(_ rawList: [[String: Any]]) -> [BaiduFileItem] {
                let parsed = parseFiles(rawList.filter { !isDirectory($0) })
                let videos = parsed.filter { baiduIsPlayableVideoFileName($0.name) }
                let skipped = parsed.count - videos.count
                if skipped > 0 {
                    baiduLog("[Baidu-iBoxRoute] 已过滤非视频文件：\(skipped) 个（如 .nfo/.srt/.ass/.jpg）")
                }
                return videos
            }

            func parseJSONStringIfNeeded(_ value: Any) -> Any {
                guard let text = value as? String else { return value }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
                      let data = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) else {
                    return value
                }
                return json
            }

            func deepString(_ value: Any, keys: Set<String>) -> String {
                let normalized = parseJSONStringIfNeeded(value)
                if let dict = normalized as? [String: Any] {
                    for (key, raw) in dict where keys.contains(key.lowercased()) {
                        let direct = stringValue(raw)
                        if !direct.isEmpty { return direct }
                    }
                    for raw in dict.values {
                        let found = deepString(raw, keys: keys)
                        if !found.isEmpty { return found }
                    }
                } else if let array = normalized as? [Any] {
                    for raw in array {
                        let found = deepString(raw, keys: keys)
                        if !found.isEmpty { return found }
                    }
                }
                return ""
            }

            func deepFiles(_ value: Any) -> [BaiduFileItem] {
                let normalized = parseJSONStringIfNeeded(value)
                if let dict = normalized as? [String: Any] {
                    for key in ["list", "file_list", "records", "filelist", "result", "data", "info"] {
                        if let rawList = dict[key] as? [[String: Any]] {
                            let parsed = parsePlayableFiles(rawList)
                            if !parsed.isEmpty { return parsed }
                        }
                        if let nested = dict[key] {
                            let parsed = deepFiles(nested)
                            if !parsed.isEmpty { return parsed }
                        }
                    }
                    for raw in dict.values {
                        let found = deepFiles(raw)
                        if !found.isEmpty { return found }
                    }
                } else if let rawList = normalized as? [[String: Any]] {
                    let parsed = parsePlayableFiles(rawList)
                    if !parsed.isEmpty { return parsed }
                } else if let array = normalized as? [Any] {
                    for raw in array {
                        let found = deepFiles(raw)
                        if !found.isEmpty { return found }
                    }
                }
                return []
            }

            func applyTemplateVariables(_ json: [String: Any], source: String, files: inout [BaiduFileItem]) {
                let templateBdstoken = deepString(json, keys: ["bdstoken"])
                let templateShareid = deepString(json, keys: ["shareid", "share_id"])
                let templateUk = deepString(json, keys: ["share_uk", "uk"])
                let templateFiles = deepFiles(json)
                if bdstoken.isEmpty, !templateBdstoken.isEmpty { bdstoken = templateBdstoken }
                if shareid.isEmpty, !templateShareid.isEmpty { shareid = templateShareid }
                if shareUk.isEmpty, !templateUk.isEmpty { shareUk = templateUk }
                if files.isEmpty, !templateFiles.isEmpty { files = templateFiles }
                baiduLog("[Baidu-iBoxRoute] \(source) templatevariable：bdstoken=\(!templateBdstoken.isEmpty), shareid=\(!templateShareid.isEmpty), uk=\(!templateUk.isEmpty), files=\(templateFiles.count), keys=\(json.keys.sorted().joined(separator: ","))")
            }

            func fetchTemplateVariables(source: String, referer: String) async -> [String: Any]? {
                var components = URLComponents(string: "https://pan.baidu.com/api/gettemplatevariable")!
                components.queryItems = [
                    URLQueryItem(name: "clienttype", value: "0"),
                    URLQueryItem(name: "app_id", value: "250528"),
                    URLQueryItem(name: "web", value: "1"),
                    URLQueryItem(name: "bdstoken", value: bdstoken),
                    URLQueryItem(name: "fields", value: #"["bdstoken","token","uk","username","shareid","share_id","share_uk","sign","timestamp","file_list","filelist","list","records","shareinfo","share_info","yunData"]"#)
                ]
                guard let url = components.url else { return nil }
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                request.setValue(iBoxCookie, forHTTPHeaderField: "Cookie")
                request.setValue(webUA, forHTTPHeaderField: "User-Agent")
                request.setValue(referer, forHTTPHeaderField: "Referer")
                request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
                request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
                do {
                    let (data, response) = try await session.data(for: request)
                    if let sc = (response as? HTTPURLResponse)?.allHeaderFields["Set-Cookie"] as? String {
                        iBoxCookie = baiduMergeCookieStrings([iBoxCookie, sc])
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        let preview = String(data: data.prefix(180), encoding: .utf8) ?? ""
                        baiduLog("[Baidu-iBoxRoute] \(source) templatevariable 非 JSON：\(preview)")
                        return nil
                    }
                    return json
                } catch {
                    baiduLog("[Baidu-iBoxRoute] \(source) templatevariable 失败：\(error.localizedDescription)")
                    return nil
                }
            }

            func applyYunDataHTML(_ html: String, source: String, files: inout [BaiduFileItem]) {
                let htmlShareid = firstHTMLValue(html, patterns: [
                    #"yunData\.SHAREID\s*=\s*["']?(\d+)"#,
                    #"["']?SHAREID["']?\s*[:=]\s*["']?(\d+)"#,
                    #"["']?shareid["']?\s*[:=]\s*["']?(\d+)"#,
                    #"["']?share_id["']?\s*[:=]\s*["']?(\d+)"#,
                    #"shareid=(\d+)"#,
                    #"data-shareid="(\d+)""#
                ])
                let htmlShareUk = firstHTMLValue(html, patterns: [
                    #"yunData\.SHARE_UK\s*=\s*["']?(\d+)"#,
                    #"["']?SHARE_UK["']?\s*[:=]\s*["']?(\d+)"#,
                    #"["']?share_uk["']?\s*[:=]\s*["']?(\d+)"#,
                    #"["']?uk["']?\s*[:=]\s*["']?(\d+)"#,
                    #"share_uk=(\d+)"#,
                    #"data-uk="(\d+)""#
                ])
                let htmlBdstoken = firstHTMLValue(html, patterns: [
                    #"yunData\.MYBDSTOKEN\s*=\s*["']([A-Za-z0-9_-]+)["']"#,
                    #"["']?bdstoken["']?\s*[:=]\s*["']([A-Za-z0-9_-]+)["']"#,
                    #"bdstoken=([A-Za-z0-9_-]+)"#
                ])
                let htmlSign = firstHTMLValue(html, patterns: [
                    #"yunData\.SIGN\s*=\s*["']([^"']+)["']"#,
                    #"["']?sign["']?\s*[:=]\s*["']([^"']+)["']"#
                ])
                let htmlTimestamp = firstHTMLValue(html, patterns: [
                    #"yunData\.TIMESTAMP\s*=\s*["']?(\d+)"#,
                    #"["']?timestamp["']?\s*[:=]\s*["']?(\d+)"#
                ])
                if shareid.isEmpty, !htmlShareid.isEmpty { shareid = htmlShareid }
                if shareUk.isEmpty, !htmlShareUk.isEmpty { shareUk = htmlShareUk }
                if bdstoken.isEmpty, !htmlBdstoken.isEmpty { bdstoken = htmlBdstoken }
                if shareSign.isEmpty, !htmlSign.isEmpty { shareSign = htmlSign }
                if shareTimestamp.isEmpty, !htmlTimestamp.isEmpty { shareTimestamp = htmlTimestamp }
                baiduLog("[Baidu-iBoxRoute] \(source) yunData：shareid=\(!htmlShareid.isEmpty), uk=\(!htmlShareUk.isEmpty), bdstoken=\(!htmlBdstoken.isEmpty), sign=\(!htmlSign.isEmpty), html=\(html.count)字符")

                if let fileInfoMatch = try? NSRegularExpression(pattern: #"yunData\.FILEINFO\s*=\s*(\[[\s\S]*?\]);"#).firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                   fileInfoMatch.numberOfRanges > 1,
                   let r = Range(fileInfoMatch.range(at: 1), in: html) {
                    let raw = String(html[r])
                    if let data = raw.data(using: .utf8),
                       let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        let parsed = parsePlayableFiles(arr)
                        if files.isEmpty, !parsed.isEmpty { files = parsed }
                        baiduLog("[Baidu-iBoxRoute] \(source) yunData.FILEINFO 解析：files=\(parsed.count)")
                    }
                }
            }

            baiduLog("[Baidu-iBoxRoute] ① GET /wap/init?surl=\(shortSurl)")
            guard let initURLObject = URL(string: initURL) else { throw DriveError.invalidShareURL }
            var initRequest = URLRequest(url: initURLObject)
            initRequest.timeoutInterval = 18
            initRequest.setValue(iBoxCookie, forHTTPHeaderField: "Cookie")
            initRequest.setValue(webUA, forHTTPHeaderField: "User-Agent")
            initRequest.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
            initRequest.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
            initRequest.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
            let (initData, initResponse) = try await session.data(for: initRequest)
            let initResp = initResponse as? HTTPURLResponse
            if let sc = initResp?.allHeaderFields["Set-Cookie"] as? String {
                iBoxCookie = baiduMergeCookieStrings([iBoxCookie, sc])
            }
            let initHTML = String(data: initData, encoding: .utf8) ?? String(data: initData, encoding: .ascii) ?? ""
            var files: [BaiduFileItem] = []
            applyYunDataHTML(initHTML, source: "wap/init", files: &files)
            if let pwd, !pwd.isEmpty {
                baiduLog("[Baidu-iBoxRoute] ② POST /share/verify?surl=\(shortSurl)")
                var allowed = CharacterSet.urlQueryAllowed
                allowed.remove(charactersIn: "&+=?#")
                let encodedPwd = pwd.addingPercentEncoding(withAllowedCharacters: allowed) ?? pwd
                let verifyURL = "https://pan.baidu.com/share/verify?t=\(Int(Date().timeIntervalSince1970 * 1000))&surl=\(shortSurl)&channel=chunlei&web=1&app_id=250528&bdstoken=&clienttype=0"
                let verifyBody = "pwd=\(encodedPwd)&vcode=&vcode_str=&channel=chunlei&web=1&app_id=250528&clienttype=0&bdstoken="
                guard let verifyURLObject = URL(string: verifyURL) else { throw DriveError.invalidShareURL }
                var verifyRequest = URLRequest(url: verifyURLObject)
                verifyRequest.httpMethod = "POST"
                verifyRequest.timeoutInterval = 18
                verifyRequest.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
                // iBox 抓包：share/verify 的 Cookie 为空。这里不能带 BDUSS/STOKEN，否则拿到的 BDCLND 会绑定到登录态上下文，
                // 后续 root-shorturl 匿名 share/list 仍可能不认，返回 errno=2。
                verifyRequest.setValue("", forHTTPHeaderField: "Cookie")
                verifyRequest.setValue(webUA, forHTTPHeaderField: "User-Agent")
                verifyRequest.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
                verifyRequest.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
                verifyRequest.setValue("*/*", forHTTPHeaderField: "Accept")
                verifyRequest.setValue("zh-Hans-001;q=1.0", forHTTPHeaderField: "Accept-Language")
                verifyRequest.httpBody = verifyBody.data(using: .utf8)
                let (verifyData, verifyResponse) = try await session.data(for: verifyRequest)
                if let sc = (verifyResponse as? HTTPURLResponse)?.allHeaderFields["Set-Cookie"] as? String {
                    iBoxCookie = baiduMergeCookieStrings([iBoxCookie, sc])
                }
                guard let verifyJSON = try? JSONSerialization.jsonObject(with: verifyData) as? [String: Any],
                      let errno = verifyJSON["errno"] as? Int else {
                    let preview = String(data: verifyData.prefix(200), encoding: .utf8) ?? ""
                    throw DriveError.noPlayURL("百度 iBox 验证返回非 JSON：\(preview)")
                }
                guard errno == 0 else {
                    let msg = baiduErrorMessage(errno: errno, fallback: verifyJSON["errmsg"] as? String ?? verifyJSON["show_msg"] as? String)
                    throw DriveError.noPlayURL("百度 iBox 验证失败：\(msg)")
                }
                if let rawRandsk = verifyJSON["randsk"] as? String, !rawRandsk.isEmpty {
                    let decodedRandsk = rawRandsk.removingPercentEncoding ?? rawRandsk
                    randskForList = decodedRandsk
                    iBoxCookie = baiduMergeCookieStrings([iBoxCookie, "BDCLND=\(rawRandsk); randsk=\(decodedRandsk)"])
                    baiduLog("[Baidu-iBoxRoute] ✅ verify 成功，已写入 BDCLND/randsk")
                }
            }

            // 密码分享必须在 verify 写入 BDCLND/randsk 后再抓桌面页，否则 /s/1xxx 会在验证页之间循环重定向。
            baiduLog("[Baidu-iBoxRoute] ②.5 GET 桌面分享页 \(desktopShareURL)")
            if let desktopURLObject = URL(string: desktopShareURL) {
                do {
                    var desktopRequest = URLRequest(url: desktopURLObject)
                    desktopRequest.timeoutInterval = 18
                    desktopRequest.setValue(iBoxCookie, forHTTPHeaderField: "Cookie")
                    desktopRequest.setValue(webUA, forHTTPHeaderField: "User-Agent")
                    desktopRequest.setValue(initURL, forHTTPHeaderField: "Referer")
                    desktopRequest.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
                    desktopRequest.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
                    let (desktopData, desktopResponse) = try await session.data(for: desktopRequest)
                    if let sc = (desktopResponse as? HTTPURLResponse)?.allHeaderFields["Set-Cookie"] as? String {
                        iBoxCookie = baiduMergeCookieStrings([iBoxCookie, sc])
                    }
                    let desktopHTML = String(data: desktopData, encoding: .utf8) ?? String(data: desktopData, encoding: .ascii) ?? ""
                    applyYunDataHTML(desktopHTML, source: "桌面页", files: &files)
                } catch {
                    baiduLog("[Baidu-iBoxRoute] 桌面分享页失败，继续走 share/list 兜底：\(error.localizedDescription)")
                }
            }

            // 对齐 iBox 报告中的 api/gettemplatevariable：必须跟在分享页上下文之后，并使用桌面分享页 Referer。
            if let templateJSON = await fetchTemplateVariables(source: "桌面页后", referer: desktopShareURL) {
                applyTemplateVariables(templateJSON, source: "桌面页后", files: &files)
            }

            baiduLog("[Baidu-iBoxRoute] ③ GET /share/list root shorturl=\(shortSurl)")
            let encodedRandsk = iBoxQueryEncoded(randskForList, keepSlash: true)
            let encodedShortSurl = queryEncoded(shortSurl)
            var lastListError = ""

            func requestShareList(_ listURL: String, source: String, includeAccountCookie: Bool) async throws -> [String: Any]? {
                guard let listURLObject = URL(string: listURL) else { return nil }
                var listRequest = URLRequest(url: listURLObject)
                listRequest.timeoutInterval = 18
                let shareCookie = cookieForShareList(iBoxCookie, includeAccount: includeAccountCookie)
                listRequest.setValue(shareCookie, forHTTPHeaderField: "Cookie")
                listRequest.setValue(webUA, forHTTPHeaderField: "User-Agent")
                listRequest.setValue("https://pan.baidu.com/", forHTTPHeaderField: "Referer")
                listRequest.setValue("*/*", forHTTPHeaderField: "Accept")
                listRequest.setValue("zh-Hans-001;q=1.0", forHTTPHeaderField: "Accept-Language")
                listRequest.setValue("https://pan.baidu.com", forHTTPHeaderField: "Origin")
                let (listData, listResponse) = try await session.data(for: listRequest)
                if let sc = (listResponse as? HTTPURLResponse)?.allHeaderFields["Set-Cookie"] as? String {
                    iBoxCookie = baiduMergeCookieStrings([iBoxCookie, sc])
                }
                guard let listJSON = try? JSONSerialization.jsonObject(with: listData) as? [String: Any] else {
                    lastListError = String(data: listData.prefix(200), encoding: .utf8) ?? "非 JSON"
                    return nil
                }
                let errno = listJSON["errno"] as? Int ?? 0
                if errno != 0 {
                    lastListError = baiduErrorMessage(errno: errno, fallback: listJSON["errmsg"] as? String ?? listJSON["show_msg"] as? String)
                    baiduLog("[Baidu-iBoxRoute] share/list(\(source)) 失败：errno=\(errno), msg=\(lastListError), hasBDCLND=\(shareCookie.lowercased().contains("bdclnd=")), shareCookieHasBDUSS=\(shareCookie.lowercased().contains("bduss=")), shareCookieHasSTOKEN=\(shareCookie.lowercased().contains("stoken=")), url=\(listURL)")
                    return nil
                }
                return listJSON
            }

            let rootURL = "https://pan.baidu.com/share/list?app_id=250528&bdstoken=&channel=chunlei&clienttype=0&desc=1&num=20&order=time&page=1&root=1&shorturl=\(encodedShortSurl)&showempty=0&view_mode=1&web=1"
            var dirsToLoad: [String] = []
            if let rootJSON = try await requestShareList(rootURL, source: "root-shorturl", includeAccountCookie: false) {
                let root = (rootJSON["data"] as? [String: Any]) ?? rootJSON
                let rootShareid = stringValue(root["share_id"]).isEmpty ? stringValue(root["shareid"]) : stringValue(root["share_id"])
                let rootUk = stringValue(root["uk"]).isEmpty ? stringValue(root["share_uk"]) : stringValue(root["uk"])
                if !rootShareid.isEmpty { shareid = rootShareid }
                if !rootUk.isEmpty { shareUk = rootUk }
                if let rawList = root["list"] as? [[String: Any]] {
                    let rootFiles = parsePlayableFiles(rawList)
                    if !rootFiles.isEmpty { files.append(contentsOf: rootFiles) }
                    dirsToLoad.append(contentsOf: rawList.filter { isDirectory($0) }.compactMap { item in
                        let path = stringValue(item["path"])
                        return path.isEmpty ? nil : path
                    })
                    baiduLog("[Baidu-iBoxRoute] root-shorturl 成功：shareid=\(!shareid.isEmpty), uk=\(!shareUk.isEmpty), files=\(rootFiles.count), dirs=\(dirsToLoad.count)")
                }
            }

            if !shareid.isEmpty, !shareUk.isEmpty, !randskForList.isEmpty {
                var seenDirs = Set<String>()
                var index = 0
                while index < dirsToLoad.count, index < 30 {
                    let dir = dirsToLoad[index]
                    index += 1
                    guard !dir.isEmpty, !seenDirs.contains(dir) else { continue }
                    seenDirs.insert(dir)
                    let dirEncoded = iBoxQueryEncoded(dir, keepSlash: true)
                    let dirURL = "https://pan.baidu.com/share/list?app_id=250528&bdstoken=&channel=chunlei&clienttype=0&desc=1&dir=\(dirEncoded)&is_from_web=true&num=100&order=other&page=1&sekey=\(encodedRandsk)&shareid=\(queryEncoded(shareid))&showempty=0&uk=\(queryEncoded(shareUk))&view_mode=1&web=1"
                    if let dirJSON = try await requestShareList(dirURL, source: "dir", includeAccountCookie: true) {
                        let root = (dirJSON["data"] as? [String: Any]) ?? dirJSON
                        if let rawList = root["list"] as? [[String: Any]] {
                            let dirFiles = parsePlayableFiles(rawList)
                            if !dirFiles.isEmpty { files.append(contentsOf: dirFiles) }
                            dirsToLoad.append(contentsOf: rawList.filter { isDirectory($0) }.compactMap { item in
                                let path = stringValue(item["path"])
                                return path.isEmpty ? nil : path
                            })
                            baiduLog("[Baidu-iBoxRoute] dir-list 成功：dir=\(dir), files=\(dirFiles.count), subdirs=\(dirsToLoad.count - index)")
                        }
                    }
                }
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
                randsk: randskForList,
                cookie: iBoxCookie,
                files: files,
                source: "ibox-wap-share-list",
                key: contextKey
            )
            baiduLog("[Baidu-iBoxRoute] ✅ shareid=\(shareid), uk=\(shareUk), 文件=\(files.count)")
            return (shareid, shareUk, bdstoken, surl, iBoxCookie, files, randskForList)
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
                if let name = item["server_filename"] as? String, name == "vbox" { return "/vbox/" }
            }
        }
        let createURL = URL(string: "https://pan.baidu.com/api/create?a=commit&bdstoken=&channel=chunlei&web=1&app_id=250528&clienttype=0")!
        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        createReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        createReq.setValue("BDUSS=\(bduss)", forHTTPHeaderField: "Cookie")
        createReq.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let params = "path=/vbox&isdir=1&block_list=[]"
        createReq.httpBody = params.data(using: .utf8)
        let _ = try? await session.data(for: createReq)
        return "/vbox/"
    }

    private func baiduDeleteFiles(fileIds: [String], bduss: String, bdstoken: String? = nil) async {
        guard !fileIds.isEmpty else { return }

        // 自动检测：bduss 是完整 Cookie 字符串还是纯 BDUSS 值
        let isFullCookie = bduss.contains(";") || bduss.lowercased().contains("stoken=")
        let cookieHeader: String
        let rawBDUSS: String
        if isFullCookie {
            cookieHeader = bduss
            rawBDUSS = baiduCookieValue(bduss, named: "BDUSS") ?? bduss
        } else {
            cookieHeader = "BDUSS=\(bduss)"
            rawBDUSS = bduss
        }

        let effectiveBdstoken: String
        if let bdstoken, !bdstoken.isEmpty {
            effectiveBdstoken = bdstoken
        } else {
            // 延迟清理场景下 bdstoken 可能已过期，实时获取
            // 使用完整 cookieHeader（含 BDUSS+STOKEN）而非仅 BDUSS，确保 gettemplatevariable 认证通过
            effectiveBdstoken = await baiduFetchUserBdstokenLocal(cookie: cookieHeader) ?? ""
        }
        guard !effectiveBdstoken.isEmpty else {
            self.log("[CloudDrive] ❌ 百度删除失败：无法获取 bdstoken，跳过 \(fileIds.count) 个文件")
            return
        }
        // 对齐 iBox 2.4.6 删除 API 格式，提升兼容性
        let url = URL(string: "https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=delete&newVerify=1&clienttype=0&app_id=250528&web=1&channel=chunlei&bdstoken=\(effectiveBdstoken)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("https://pan.baidu.com/disk/main", forHTTPHeaderField: "Referer")
        // 支持 fileId 或 path 两种格式：path 以 / 开头，fileId 是纯数字
        let paths = fileIds.map { $0.hasPrefix("/") ? $0 : "/vbox/\($0)" }
        let filelistJSON = (try? JSONSerialization.data(withJSONObject: paths))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let params = "filelist=\(filelistJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filelistJSON)"
        req.httpBody = params.data(using: .utf8)
        // 解析删除 API 响应，校验 errno 判断删除是否成功
        if let (data, _) = try? await session.data(for: req),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let errno = json["errno"] as? Int ?? -1
            if errno == 0 {
                self.log("[CloudDrive] ✅ 百度已删除转存文件: \(paths)")
            } else {
                let errMsg = (json["errmsg"] as? String) ?? (json["error_msg"] as? String) ?? ""
                self.log("[CloudDrive] ❌ 百度删除失败 errno=\(errno)\(errMsg.isEmpty ? "" : " msg=\(errMsg)")，文件: \(paths)")
            }
        } else {
            self.log("[CloudDrive] ❌ 百度删除请求网络失败: \(paths)")
        }
    }

    /// 异步清理 /vbox/ 目录下超过2小时的旧转存文件，不阻塞调用方
    private func baiduCleanupOldTransferFiles(cookie: String, bdstoken: String) {
        baiduLog("[Baidu-Cleanup] 🔧 baiduCleanupOldTransferFiles 入口，bdstoken=\(bdstoken.prefix(8))…")
        // 守卫：bdstoken 为空时无法调用任何百度 API，直接跳过
        guard !bdstoken.isEmpty else {
            baiduLog("[Baidu-Cleanup] ⚠️ bdstoken 为空，跳过旧文件清理")
            return
        }
        guard let bdussVal = baiduCookieValue(cookie, named: "BDUSS") else {
            baiduLog("[Baidu-Cleanup] ⚠️ Cookie 中缺少 BDUSS，跳过旧文件清理")
            return
        }
        baiduLog("[Baidu-Cleanup] 🔧 守卫通过，BDUSS=\(bdussVal.prefix(8))…")

        Task {
            do {
                // 直接使用传入的 bdstoken，不再重新获取。
                // earlyPureCookie 经过过滤后可能缺少 BAIDUID 等字段，导致 gettemplatevariable 返回 errno=-6。
                // 传入的 bdstoken 是在 resolveBaiduPlayURLViaMainRoute 入口处通过完整 Cookie 获取的，有效。
                let freshBdstoken = bdstoken
                baiduLog("[Baidu-Cleanup] 🔧 使用传入的 bdstoken=\(freshBdstoken.prefix(8))…，cutoff=\(Date().addingTimeInterval(-2 * 3600))")

                let cutoff = Date().addingTimeInterval(-2 * 3600) // 2小时前
                let encodedDir = Self.baiduIBoxTransferDir.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? Self.baiduIBoxTransferDir

                // 分页列出 /vbox/ 目录，每页 200 个，最多 5 页（1000 个文件）
                var allFiles: [[String: Any]] = []
                for page in 1...5 {
                    let listURL = URL(string: "https://pan.baidu.com/api/list")!
                    var components = URLComponents(url: listURL, resolvingAgainstBaseURL: false)!
                    components.queryItems = [
                        URLQueryItem(name: "bdstoken", value: freshBdstoken),
                        URLQueryItem(name: "channel", value: "chunlei"),
                        URLQueryItem(name: "web", value: "1"),
                        URLQueryItem(name: "app_id", value: "250528"),
                        URLQueryItem(name: "clienttype", value: "0")
                    ]
                    var req = URLRequest(url: components.url!)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 12
                    req.setValue(cookie, forHTTPHeaderField: "Cookie")
                    req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
                    req.setValue("https://pan.baidu.com/disk/main", forHTTPHeaderField: "Referer")
                    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    req.httpBody = "dir=\(encodedDir)&order=time&desc=1&num=200&page=\(page)".data(using: .utf8)

                    let (data, _) = try await session.data(for: req)
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        baiduLog("[Baidu-Cleanup] ⚠️ api/list 第\(page)页 JSON 解析失败")
                        break
                    }
                    let listErrno = json["errno"] as? Int ?? -1
                    guard listErrno == 0 else {
                        baiduLog("[Baidu-Cleanup] ⚠️ api/list 第\(page)页 errno=\(listErrno)")
                        break
                    }
                    // 对齐 baiduFindExistingVboxPath：兼容 api/list 多种返回格式
                    let root = (json["data"] as? [String: Any]) ?? json
                    let list = root["list"] as? [[String: Any]]
                        ?? root["file_list"] as? [[String: Any]]
                        ?? root["records"] as? [[String: Any]]
                    guard let list = list, !list.isEmpty else {
                        baiduLog("[Baidu-Cleanup] ℹ️ api/list 第\(page)页无数据，结束分页")
                        break
                    }
                    allFiles.append(contentsOf: list)
                    if list.count < 200 { break }
                }
                guard !allFiles.isEmpty else {
                    baiduLog("[Baidu-Cleanup] ⚠️ /vbox/ 目录为空或 api/list 全部失败，跳过清理")
                    return
                }

                baiduLog("[Baidu-Cleanup] 🔧 api/list 成功获取 \(allFiles.count) 个文件")

                // 找出超过2小时的文件
                // 百度 api/list 返回的时间戳字段为 server_ctime / server_mtime
                let oldFiles: [[String: Any]] = allFiles.filter { item in
                    let ctime = (item["server_ctime"] as? Int)
                        ?? (item["ctime"] as? Int)
                        ?? (item["local_ctime"] as? Int)
                        ?? 0
                    let mtime = (item["server_mtime"] as? Int)
                        ?? (item["mtime"] as? Int)
                        ?? (item["local_mtime"] as? Int)
                        ?? 0
                    let timestamp = max(ctime, mtime)
                    // 首次执行时打印每个文件的时间戳信息用于诊断
                    if let fname = item["server_filename"] as? String ?? item["path"] as? String {
                        baiduLog("[Baidu-Cleanup] 🔍 文件：\(fname)，server_ctime=\(item["server_ctime"] ?? "nil")，server_mtime=\(item["server_mtime"] ?? "nil")，mtime=\(item["mtime"] ?? "nil")，计算timestamp=\(timestamp)")
                    }
                    guard timestamp > 0 else { return false }
                    let fileDate = Date(timeIntervalSince1970: Double(timestamp))
                    return fileDate < cutoff
                }

                guard !oldFiles.isEmpty else {
                    baiduLog("[Baidu-Cleanup] ℹ️ /vbox/ 目录无超过2小时的旧文件（共 \(allFiles.count) 个文件，截止 \(cutoff)）")
                    return
                }

                // 批量删除
                let paths = oldFiles.compactMap { $0["path"] as? String }
                baiduLog("[Baidu-Cleanup] 🔍 待删除文件路径：\(paths)")
                let encodedList = try? JSONSerialization.data(withJSONObject: paths)
                let fileListStr = String(data: encodedList ?? Data(), encoding: .utf8) ?? "[]"
                baiduLog("[Baidu-Cleanup] 🔍 filelist 原始值：\(fileListStr)")
                let encodedFileList = fileListStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileListStr
                baiduLog("[Baidu-Cleanup] 🔍 filelist 编码后：\(encodedFileList)")
                let bodyStr = "filelist=\(encodedFileList)"
                baiduLog("[Baidu-Cleanup] 🔍 删除请求 body：\(bodyStr)")
                baiduLog("[Baidu-Cleanup] 🔍 删除请求 Cookie BDUSS=\(baiduCookieValue(cookie, named: "BDUSS")?.prefix(8) ?? "nil")… STOKEN=\(baiduCookieValue(cookie, named: "STOKEN")?.prefix(8) ?? "nil")… bdstoken=\(freshBdstoken.prefix(8))…")

                // 对齐 iBox 删除 API 格式
                let deleteURL = URL(string: "https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=delete&newVerify=1&clienttype=0&app_id=250528&web=1&channel=chunlei&bdstoken=\(freshBdstoken)")!
                var delReq = URLRequest(url: deleteURL)
                delReq.httpMethod = "POST"
                delReq.timeoutInterval = 12
                delReq.setValue(cookie, forHTTPHeaderField: "Cookie")
                delReq.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
                delReq.setValue("https://pan.baidu.com/disk/main", forHTTPHeaderField: "Referer")
                delReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                delReq.httpBody = bodyStr.data(using: .utf8)

                if let (delData, delResp) = try? await session.data(for: delReq),
                   let delJson = try? JSONSerialization.jsonObject(with: delData) as? [String: Any] {
                    let delErrno = delJson["errno"] as? Int ?? -1
                    if delErrno == 0 {
                        baiduLog("[Baidu-Cleanup] ✅ 已清理 \(oldFiles.count) 个超过2小时的旧转存文件")
                    } else {
                        let delErrMsg = (delJson["errmsg"] as? String) ?? (delJson["error_msg"] as? String) ?? ""
                        baiduLog("[Baidu-Cleanup] ❌ 批量删除失败 errno=\(delErrno)\(delErrMsg.isEmpty ? "" : " msg=\(delErrMsg)")")
                    }
                    baiduLog("[Baidu-Cleanup] 🔍 删除完整响应 HTTP \((delResp as? HTTPURLResponse)?.statusCode ?? 0)：\(String(data: delData, encoding: .utf8) ?? "(非UTF8)")")
                } else {
                    baiduLog("[Baidu-Cleanup] ❌ 批量删除请求网络失败")
                }
            } catch {
                baiduLog("[Baidu-Cleanup] ⚠️ 清理旧转存文件失败（不影响播放）：\(error.localizedDescription)")
            }
        }
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

    // MARK: - 123云盘

    func resolve123PanPlayURL(shareURL: String, token: String) async throws -> PlayResult {
        print("[123Pan] 开始解析: \(shareURL)")
        let shareCode = extract123PanShareCode(from: shareURL)
        guard !shareCode.isEmpty else { throw DriveError.invalidShareURL }

        let headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            "Referer": "https://www.123pan.com/",
            "Origin": "https://www.123pan.com"
        ]

        let accessToken = CloudDriveAuthManager.shared.credential(for: .pan123)?.accessToken

        // 123云盘分享解析API（使用 URLComponents 避免 shareCode 未编码）
        var components = URLComponents(string: "https://www.123pan.com/b/api/share/get")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "next", value: "1"),
            URLQueryItem(name: "orderBy", value: "share_id"),
            URLQueryItem(name: "orderDirection", value: "desc"),
            URLQueryItem(name: "shareKey", value: shareCode),
            URLQueryItem(name: "SharePwd", value: ""),
            URLQueryItem(name: "ParentFileId", value: "0"),
            URLQueryItem(name: "Page", value: "1")
        ]
        guard let apiURL = components.url else {
            throw DriveError.invalidShareURL
        }
        var request = URLRequest(url: apiURL)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "Cookie")
        if let accessToken = accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.noPlayURL("123云盘: 分享列表返回无法解析")
        }
        // 先检查 code 是否表示失败
        if let code = json["code"] as? Int, code != 0, code != 200 {
            let msg = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("123云盘: 分享列表接口返回错误: \(msg)")
        }
        if let code = json["code"] as? String, code != "0", code != "200", code.lowercased() != "ok" {
            let msg = json["message"] as? String ?? code
            throw DriveError.noPlayURL("123云盘: 分享列表接口返回错误: \(msg)")
        }
        guard let dataObj = json["data"] as? [String: Any],
              let list = dataObj["InfoList"] as? [[String: Any]],
              let firstFile = list.first else {
            throw DriveError.noPlayURL("123云盘: 无法获取文件列表")
        }

        // 兼容 fileId 为 Int/String，eTag 字段大小写
        let fileId: Any
        if let id = firstFile["FileId"] as? Int {
            fileId = id
        } else if let idStr = firstFile["FileId"] as? String, !idStr.isEmpty {
            fileId = idStr
        } else {
            throw DriveError.noPlayURL("123云盘: 无法提取文件信息")
        }
        let eTag = firstFile["Etag"] as? String
            ?? firstFile["ETag"] as? String
            ?? firstFile["etag"] as? String
        guard let eTag, !eTag.isEmpty else {
            throw DriveError.noPlayURL("123云盘: 无法提取 ETag")
        }

        // 获取下载链接
        let downloadURL = URL(string: "https://www.123pan.com/a/api/file/download_info")!
        var downloadReq = URLRequest(url: downloadURL)
        downloadReq.httpMethod = "POST"
        downloadReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        downloadReq.setValue(token, forHTTPHeaderField: "Cookie")
        if let accessToken = accessToken, !accessToken.isEmpty {
            downloadReq.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in headers { downloadReq.setValue(v, forHTTPHeaderField: k) }
        let body: [String: Any] = ["fileId": fileId, "etag": eTag, "shareKey": shareCode, "SharePwd": ""]
        downloadReq.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (dlData, _) = try await session.data(for: downloadReq)
        guard let dlJson = try JSONSerialization.jsonObject(with: dlData) as? [String: Any],
              let dlDataObj = dlJson["data"] as? [String: Any] else {
            throw DriveError.noPlayURL("123云盘: 无法获取下载链接")
        }
        let downloadUrl = dlDataObj["DownloadUrl"] as? String
            ?? dlDataObj["download_url"] as? String
            ?? dlDataObj["url"] as? String
        guard let downloadUrl, !downloadUrl.isEmpty else {
            throw DriveError.noPlayURL("123云盘: 下载链接为空")
        }

        return PlayResult(
            url: downloadUrl,
            headers: headers,
            driveType: .pan123,
            source: "123pan_direct"
        )
    }

    private func extract123PanShareCode(from url: String) -> String {
        if let range = url.range(of: #"/s/([a-zA-Z0-9\-]+)"#, options: .regularExpression) {
            return String(url[range]).replacingOccurrences(of: "/s/", with: "")
        }
        return ""
    }

    // MARK: - 139云盘

    func resolve139PanPlayURL(shareURL: String, cookie: String) async throws -> PlayResult {
        print("[139Pan] 开始解析: \(shareURL)")

        let headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (Linux; Android 10; SM-G960U) AppleWebKit/537.36",
            "Referer": "https://yun.139.com/",
            "Origin": "https://yun.139.com",
            "Cookie": cookie
        ]

        // 139云盘分享链接解析
        // 139云盘分享格式: https://yun.139.com/link/w/i/xxx 或 https://caiyun.139.com/w/i/xxx
        guard let urlComponents = URLComponents(string: shareURL),
              let path = urlComponents.path.components(separatedBy: "/").last,
              !path.isEmpty else {
            throw DriveError.invalidShareURL
        }

        // 调用139云盘开放API获取分享内容
        let apiURL = URL(string: "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/getContentInfoFromOutLink")!
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let body: [String: Any] = ["linkId": path, "password": ""]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await session.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let contentList = dataObj["contentList"] as? [[String: Any]],
              let firstFile = contentList.first else {
            throw DriveError.noPlayURL("139云盘: 无法获取分享内容")
        }

        guard let contentId = firstFile["contentId"] as? String,
              let catalogId = firstFile["catalogId"] as? String else {
            throw DriveError.noPlayURL("139云盘: 无法提取文件信息")
        }

        // 获取下载链接
        let downloadURL = URL(string: "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink/getContentDownloadUrl")!
        var downloadReq = URLRequest(url: downloadURL)
        downloadReq.httpMethod = "POST"
        downloadReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { downloadReq.setValue(v, forHTTPHeaderField: k) }
        let dlBody: [String: Any] = [
            "contentId": contentId,
            "catalogId": catalogId,
            "linkId": path
        ]
        downloadReq.httpBody = try JSONSerialization.data(withJSONObject: dlBody)

        let (dlData, _) = try await session.data(for: downloadReq)
        guard let dlJson = try JSONSerialization.jsonObject(with: dlData) as? [String: Any],
              let dlDataObj = dlJson["data"] as? [String: Any],
              let downloadUrl = dlDataObj["downloadUrl"] as? String else {
            throw DriveError.noPlayURL("139云盘: 无法获取下载链接")
        }

        return PlayResult(
            url: downloadUrl,
            headers: headers,
            driveType: .pan139,
            source: "139pan_direct"
        )
    }

    // MARK: - 天翼云盘

    func resolve189PanPlayURL(shareURL: String, cookie: String) async throws -> PlayResult {
        print("[189Pan] 开始解析: \(shareURL)")

        let headers: [String: String] = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15",
            "Referer": "https://cloud.189.cn/",
            "Origin": "https://cloud.189.cn",
            "Cookie": cookie
        ]

        // 天翼云盘分享格式: https://cloud.189.cn/web/share?code=xxx 或 ?code=xxx#passcode
        guard let url = URL(string: shareURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DriveError.invalidShareURL
        }

        // 提取 shareCode
        var shareCode = ""
        if let codeItem = components.queryItems?.first(where: { $0.name == "code" }) {
            shareCode = codeItem.value ?? ""
        }
        // 也尝试从路径中提取
        if shareCode.isEmpty, let path = URLComponents(string: shareURL)?.path {
            let parts = path.components(separatedBy: "/")
            if let last = parts.last, !last.isEmpty {
                shareCode = last
            }
        }
        guard !shareCode.isEmpty else {
            throw DriveError.invalidShareURL
        }

        // 提取 passCode（如果分享链接有密码）
        var accessCode = ""
        if let fragment = url.fragment, !fragment.isEmpty {
            // 天翼云盘密码在 URL fragment 中
            accessCode = fragment
        } else if let pwdItem = components.queryItems?.first(where: { $0.name == "pwd" || $0.name == "accessCode" }) {
            accessCode = pwdItem.value ?? ""
        }

        print("[189Pan] shareCode=\(shareCode), accessCode=\(accessCode.isEmpty ? "无" : accessCode)")

        // 步骤1: 获取分享信息
        let shareInfoURL = URL(string: "https://cloud.189.cn/api/open/share/getShareInfoByCodeV2.action")!
        var shareReq = URLRequest(url: shareInfoURL)
        shareReq.httpMethod = "POST"
        shareReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { shareReq.setValue(v, forHTTPHeaderField: k) }

        var shareBody = "shareCode=\(shareCode)"
        if !accessCode.isEmpty {
            shareBody += "&accessCode=\(accessCode)"
        }

        shareReq.httpBody = shareBody.data(using: .utf8)
        let (shareData, shareResp) = try await session.data(for: shareReq)
        guard let httpResp = shareResp as? HTTPURLResponse else {
            throw DriveError.invalidResponse
        }

        // 如果返回302重定向到登录页，说明 Cookie 已过期
        if httpResp.statusCode == 302 {
            if let location = httpResp.allHeaderFields["Location"] as? String,
               location.contains("login") {
                throw DriveError.noPlayURL("天翼云盘: Cookie 已过期，请重新登录")
            }
        }

        guard let shareJson = try JSONSerialization.jsonObject(with: shareData) as? [String: Any] else {
            throw DriveError.noPlayURL("天翼云盘: 无法解析分享信息响应")
        }

        print("[189Pan] 分享信息响应: \(shareJson.keys)")

        // 检查响应格式
        if let resCode = shareJson["res_code"] as? Int, resCode != 0 {
            let msg = shareJson["res_message"] as? String ?? "未知错误"
            // 某些版本返回外层 code/message
            if let errCode = shareJson["code"] as? String, errCode != "0" {
                throw DriveError.noPlayURL("天翼云盘: \(shareJson["msg"] as? String ?? errCode)")
            }
            throw DriveError.noPlayURL("天翼云盘: \(msg)")
        }

        // 响应可能有两种格式
        var fileId = ""
        var shareId: Int64 = 0
        var fileName = ""

        // 格式1: 直接有 fileId/fileName
        if let fid = shareJson["fileId"] as? String, !fid.isEmpty {
            fileId = fid
        } else if let fid = shareJson["fileId"] as? Int64 {
            fileId = String(fid)
        }
        if let sid = shareJson["shareId"] as? Int64 {
            shareId = sid
        } else if let sid = shareJson["shareId"] as? String {
            shareId = Int64(sid) ?? 0
        }
        if let fn = shareJson["fileName"] as? String {
            fileName = fn
        }

        // 格式2: 嵌套在 data 中
        if fileId.isEmpty, let dataObj = shareJson["data"] as? [String: Any] {
            if let fid = dataObj["fileId"] as? String {
                fileId = fid
            } else if let fid = dataObj["fileId"] as? Int64 {
                fileId = String(fid)
            }
            if let sid = dataObj["shareId"] as? Int64 {
                shareId = sid
            } else if let sid = dataObj["shareId"] as? String {
                shareId = Int64(sid) ?? 0
            }
            if let fn = dataObj["fileName"] as? String {
                fileName = fn
            }
            if shareId == 0, let sidStr = dataObj["shareId"] as? String {
                shareId = Int64(sidStr) ?? 0
            }
        }

        guard !fileId.isEmpty else {
            print("[189Pan] 无法提取 fileId，完整响应: \(shareJson)")
            throw DriveError.noPlayURL("天翼云盘: 无法提取文件信息")
        }

        print("[189Pan] fileId=\(fileId), shareId=\(shareId), fileName=\(fileName)")

        // 步骤2: 获取下载链接
        let downloadURL = URL(string: "https://cloud.189.cn/api/open/share/getFileDownloadUrl.action")!
        var dlReq = URLRequest(url: downloadURL)
        dlReq.httpMethod = "POST"
        dlReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { dlReq.setValue(v, forHTTPHeaderField: k) }

        var dlBody = "fileId=\(fileId)"
        if shareId != 0 {
            dlBody += "&shareId=\(shareId)"
        }
        dlReq.httpBody = dlBody.data(using: .utf8)

        let (dlData, _) = try await session.data(for: dlReq)
        guard let dlJson = try JSONSerialization.jsonObject(with: dlData) as? [String: Any] else {
            throw DriveError.noPlayURL("天翼云盘: 无法解析下载链接响应")
        }

        print("[189Pan] 下载链接响应 keys: \(dlJson.keys)")

        // 检查响应
        if let resCode = dlJson["res_code"] as? Int, resCode != 0 {
            let msg = dlJson["res_message"] as? String ?? "未知错误"
            throw DriveError.noPlayURL("天翼云盘: 获取下载链接失败 - \(msg)")
        }

        var downloadUrlStr = ""

        // 格式1: 直接在 data 中
        if let dataObj = dlJson["data"] as? [String: Any] {
            if let url = dataObj["fileDownloadUrl"] as? String, !url.isEmpty {
                downloadUrlStr = url
            } else if let url = dataObj["downloadUrl"] as? String, !url.isEmpty {
                downloadUrlStr = url
            } else if let url = dataObj["url"] as? String, !url.isEmpty {
                downloadUrlStr = url
            }
        }

        // 格式2: 直接在顶层
        if downloadUrlStr.isEmpty {
            if let url = dlJson["fileDownloadUrl"] as? String, !url.isEmpty {
                downloadUrlStr = url
            } else if let url = dlJson["downloadUrl"] as? String, !url.isEmpty {
                downloadUrlStr = url
            } else if let url = dlJson["url"] as? String, !url.isEmpty {
                downloadUrlStr = url
            }
        }

        guard !downloadUrlStr.isEmpty else {
            print("[189Pan] 无法提取下载链接，完整响应: \(dlJson)")
            throw DriveError.noPlayURL("天翼云盘: 无法获取下载链接")
        }

        print("[189Pan] 获取到下载链接: \(downloadUrlStr.prefix(80))...")

        // 构建播放请求头（包含 Cookie 和 Referer）
        var playHeaders: [String: String] = [
            "User-Agent": headers["User-Agent"] ?? "",
            "Referer": "https://cloud.189.cn/",
            "Origin": "https://cloud.189.cn"
        ]

        return PlayResult(
            url: downloadUrlStr,
            headers: playHeaders,
            driveType: .pan189,
            source: "189pan_direct"
        )
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

        // 尝试获取文件列表，stoken 失效时自动刷新
        let resolveResult = try await ucResolveUCShareFile(
            pwdId: pwdId,
            passcode: passcode,
            stoken: stoken,
            folderId: folder.folderId,
            cookie: authCookie
        )
        let sourceFile = resolveResult.sourceFile
        let fileId = resolveResult.fileId
        let fileIds = resolveResult.fileIds
        print("[UC] 最终选中资源：\(sourceFile.fileName), fid=\(fileId)")

        var transcodeURL = ""
        do {
            transcodeURL = try await ucGetPlayURL(fileId: fileId, cookie: authCookie)
        } catch {
            print("[UC] ⚠️ v2/play 失败，继续尝试：\(error.localizedDescription)")
        }
        let downloadURL = try await ucGetDownloadURL(fileId: fileId, cookie: authCookie)

        // 优先级：TV Token（高速） > v2/play（转码） > download_url（慢速）
        var playURL = ""
        var source = ""

        if let tvToken = CloudDriveAuthManager.shared.credential(for: .uc)?.extra["uc_tv_token"],
           !tvToken.isEmpty {
            self.log("[CloudDrive] 🔍 检测到 UC TV Token，走高速通道")
            do {
                playURL = try await ucGetPlayURLWithTVToken(fileId: fileId, tvToken: tvToken)
                source = "uc_tv_token"
                self.log("[CloudDrive] ✅ TV Token 高速通道成功")
            } catch {
                self.log("[CloudDrive] ⚠️ TV Token 失败，降级: \(error.localizedDescription)")
            }
        } else {
            self.log("[CloudDrive] ℹ️ 无 TV Token，使用 Cookie 通道")
        }

        if playURL.isEmpty && !transcodeURL.isEmpty {
            playURL = transcodeURL
            source = "v2-play"
        }

        if playURL.isEmpty {
            playURL = downloadURL
            source = "download_url"
        }

        guard !playURL.isEmpty else { throw DriveError.noPlayURL("UC: download_url、转码地址和 UCTV Token 兜底均为空") }

        self.log("[CloudDrive] ℹ️ UC 播放源: \(source)")
        if source == "uc_tv_token" {
            self.log("[CloudDrive] 🔗 TV CDN: \(playURL.prefix(100))")
        }

        scheduleCleanup(drive: .uc, fileIds: fileIds, token: authCookie, delay: 60 * 60)

        // TV Token 返回的是 CDN 直链，不需要 UC Cookie，否则 CDN 可能拒绝请求
        let headers: [String: String]
        let fallbackHeaders: [String: String]?
        if source == "uc_tv_token" {
            headers = [
                "User-Agent": "Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2004J7AC Build/UKQ1.231108.001) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1",
                "Referer": "https://drive.uc.cn/",
                "Accept": "*/*"
            ]
            // TV Token 失败时降级到 v2/play（m3u8 流），不是 download_url
            fallbackHeaders = !transcodeURL.isEmpty ? ucPlaybackHeaders(cookie: authCookie) : nil
        } else {
            headers = ucPlaybackHeaders(cookie: authCookie)
            fallbackHeaders = (!downloadURL.isEmpty && !transcodeURL.isEmpty && source != "v2-play") ? headers : nil
        }

        let fallbackURL: String?
        let fallbackSource: String?
        if source == "uc_tv_token" {
            fallbackURL = !transcodeURL.isEmpty ? transcodeURL : (!downloadURL.isEmpty ? downloadURL : nil)
            fallbackSource = !transcodeURL.isEmpty ? "v2-play-m3u8" : (!downloadURL.isEmpty ? "download_url" : nil)
        } else {
            fallbackURL = (!downloadURL.isEmpty && !transcodeURL.isEmpty && source != "v2-play") ? transcodeURL : nil
            fallbackSource = (!downloadURL.isEmpty && !transcodeURL.isEmpty && source != "v2-play") ? "v2-play-m3u8" : nil
        }

        return PlayResult(
            url: playURL,
            headers: headers,
            driveType: .uc,
            source: source,
            fallbackURL: fallbackURL,
            fallbackHeaders: fallbackHeaders,
            fallbackSource: fallbackSource
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
            "User-Agent": "Mozilla/5.0 (Linux; Android 12; HD1900 Build/SKQ1.211113.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/97.0.4692.98 Mobile Safari/537.36",
            "Referer": "https://drive.uc.cn/",
            "Origin": "https://drive.uc.cn",
            "Accept": "*/*"
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

        let (data, _) = try await ucSession.data(for: request)

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

        let (data, _) = try await ucSession.data(for: request)
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

    private struct UCResolveResult {
        let sourceFile: UCShareFile
        let fileId: String
        let fileIds: [String]
    }

    private func ucResolveUCShareFile(pwdId: String, passcode: String, stoken: String, folderId: String, cookie: String) async throws -> UCResolveResult {
        // 1. 正常路径
        do {
            let sourceFile = try await ucFirstPlayableFile(pwdId: pwdId, stoken: stoken, pdirFid: "0", cookie: cookie)
            print("[UC] 选中资源：\(sourceFile.fileName), fid=\(sourceFile.fid)")
            let fileIds = try await ucSaveShare(pwdId: pwdId, stoken: stoken, file: sourceFile, folderId: folderId, cookie: cookie)
            guard let fileId = fileIds.first else { throw DriveError.noPlayURL("UC: 转存后未返回文件ID") }
            return UCResolveResult(sourceFile: sourceFile, fileId: fileId, fileIds: fileIds)
        } catch let error as DriveError {
            let errMsg = error.localizedDescription
            if errMsg.contains("非法token") || errMsg.contains("token") {
                self.log("[CloudDrive] ⚠️ stoken 失效，尝试刷新...")
                // 2. 刷新 stoken 并重试
                do {
                    let newStoken = try await ucGetShareToken(pwdId: pwdId, passcode: passcode, cookie: cookie)
                    let sf = try await ucFirstPlayableFile(pwdId: pwdId, stoken: newStoken, pdirFid: "0", cookie: cookie)
                    print("[UC] stoken 刷新后选中资源：\(sf.fileName), fid=\(sf.fid)")
                    let fileIds = try await ucSaveShare(pwdId: pwdId, stoken: newStoken, file: sf, folderId: folderId, cookie: cookie)
                    guard let fileId = fileIds.first else { throw DriveError.noPlayURL("UC: 转存后未返回文件ID") }
                    self.log("[CloudDrive] ✅ stoken 刷新成功")
                    return UCResolveResult(sourceFile: sf, fileId: fileId, fileIds: fileIds)
                } catch {
                    // 3. TV Token 兜底
                    if let tvToken = CloudDriveAuthManager.shared.credential(for: .uc)?.extra["uc_tv_token"],
                       !tvToken.isEmpty {
                        self.log("[CloudDrive] 🔄 stoken 刷新失败，尝试 TV Token 兜底...")
                        let tvFiles = try await ucListFilesWithTVToken(tvToken: tvToken)
                        let playable = tvFiles.first(where: { f in
                            let name = f["filename"] as? String ?? ""
                            let isDir = (f["isdir"] as? Int) == 1
                            return !isDir && quarkIsPlayableFileName(name)
                        })
                        if let pf = playable, let fid = pf["fid"] as? String {
                            self.log("[CloudDrive] ✅ TV Token 兜底找到文件: \(pf["filename"] as? String ?? "")")
                            return UCResolveResult(
                                sourceFile: UCShareFile(fid: fid, fileName: pf["filename"] as? String ?? "", shareFidToken: "", pdirFid: "0", isDir: false),
                                fileId: fid,
                                fileIds: [fid]
                            )
                        } else {
                            self.log("[CloudDrive] ❌ TV Token 兜底也未找到可播放文件")
                            throw error
                        }
                    } else {
                        throw error
                    }
                }
            } else {
                throw error
            }
        }
    }

    private func ucEnsureFolder(cookie: String) async throws -> String {
        (try await ucEnsureFolderWithCookie(cookie: cookie)).folderId
    }

    private func ucEnsureFolderWithCookie(cookie: String) async throws -> (folderId: String, cookie: String) {
        let sortQueryItems: [URLQueryItem] = [
            URLQueryItem(name: "pdir_fid", value: "0"),
            URLQueryItem(name: "_sort", value: "file_type:asc,file_name:asc"),
            URLQueryItem(name: "_page", value: "1"),
            URLQueryItem(name: "_size", value: "100"),
            URLQueryItem(name: "_fetch_total", value: "1")
        ]
        let listURL = ucAPIURL("/1/clouddrive/file/sort", extra: sortQueryItems)
        var req = URLRequest(url: listURL)
        req.httpMethod = "GET"
        ucSetCommonHeaders(&req, cookie: cookie)
        let (listData, listResp) = try await ucSession.data(for: req)
        let mergedCookie = quarkMergeSetCookie(from: listResp, into: cookie)
        let listBody = String(data: listData, encoding: .utf8) ?? "nil"
        print("[UC] ensureFolder list 响应: \(listBody.prefix(500))")
        if let listJson = try? JSONSerialization.jsonObject(with: listData) as? [String: Any] {
            if let code = listJson["code"] as? Int, code != 0 {
                print("[UC] ensureFolder list 返回 code=\(code): \(listJson["message"] as? String ?? "")")
                if code == 10001 || code == 10002 || code == 10003 {
                    throw DriveError.noPlayURL("UC: Cookie 可能已失效，请重新登录 (list code=\(code))")
                }
            }
            if let data = listJson["data"] as? [String: Any],
               let files = data["list"] as? [[String: Any]] {
                for f in files {
                    if let name = f["file_name"] as? String, name == "vbox",
                       let fid = f["fid"] as? String { return (fid, mergedCookie) }
                }
            }
            if let files = listJson["data"] as? [[String: Any]] {
                for f in files {
                    if let name = f["file_name"] as? String, name == "vbox",
                       let fid = f["fid"] as? String { return (fid, mergedCookie) }
                }
            }
        }

        let cookieAfterList = mergedCookie

        let createURL = ucAPIURL("/1/clouddrive/file")
        var createReq = URLRequest(url: createURL)
        createReq.httpMethod = "POST"
        ucSetCommonHeaders(&createReq, cookie: cookieAfterList)
        let createBody: [String: Any] = ["pdir_fid": "0", "file_name": "vbox", "dir": true, "dir_path": ""]
        createReq.httpBody = try JSONSerialization.data(withJSONObject: createBody)
        let (createData, createResp) = try await ucSession.data(for: createReq)
        let createMergedCookie = quarkMergeSetCookie(from: createResp, into: cookieAfterList)
        let createBodyStr = String(data: createData, encoding: .utf8) ?? "nil"
        print("[UC] ensureFolder create 响应: \(createBodyStr.prefix(300))")
        if let createJson = try? JSONSerialization.jsonObject(with: createData) as? [String: Any] {
            if let code = createJson["code"] as? Int, code != 0 {
                if code == 23008 {
                    print("[UC] ensureFolder create: 文件夹已存在 (code=23008)，重新 list")
                } else {
                    let msg = createJson["message"] as? String ?? "code=\(code)"
                    throw DriveError.noPlayURL("UC: Cookie 可能已失效，请重新登录 (create code=\(code) msg=\(msg))")
                }
            }
            if let code = createJson["code"] as? Int, code == 0,
               let d = createJson["data"] as? [String: Any],
               let fid = d["fid"] as? String {
                return (fid, createMergedCookie)
            }
        }

        // 文件夹可能已存在（code=23008 或 code 非 0），用 GET 重新 list
        let cookieAfterCreate = createMergedCookie
        let reListURL = ucAPIURL("/1/clouddrive/file/sort", extra: sortQueryItems)
        var reReq = URLRequest(url: reListURL)
        reReq.httpMethod = "GET"
        ucSetCommonHeaders(&reReq, cookie: cookieAfterCreate)
        let (reData, reResp) = try await ucSession.data(for: reReq)
        let reMergedCookie = quarkMergeSetCookie(from: reResp, into: cookieAfterCreate)
        let reBodyStr = String(data: reData, encoding: .utf8) ?? "nil"
        print("[UC] ensureFolder re-list 响应: \(reBodyStr.prefix(300))")
        if let reJson = try? JSONSerialization.jsonObject(with: reData) as? [String: Any] {
            if let code = reJson["code"] as? Int, code != 0 {
                print("[UC] ensureFolder re-list 返回 code=\(code): \(reJson["message"] as? String ?? "")")
                if code == 10001 || code == 10002 || code == 10003 {
                    throw DriveError.noPlayURL("UC: Cookie 可能已失效，请重新登录 (re-list code=\(code))")
                }
            }
            if let data = reJson["data"] as? [String: Any],
               let files = data["list"] as? [[String: Any]] {
                for f in files {
                    if let name = f["file_name"] as? String, name == "vbox",
                       let fid = f["fid"] as? String { return (fid, reMergedCookie) }
                }
            }
            if let files = reJson["data"] as? [[String: Any]] {
                for f in files {
                    if let name = f["file_name"] as? String, name == "vbox",
                       let fid = f["fid"] as? String { return (fid, reMergedCookie) }
                }
            }
        }
        throw DriveError.noPlayURL("UC: 无法找到或创建 vbox 文件夹")
    }

    private func ucDeleteFiles(fileIds: [String], cookie: String) async {
        guard !fileIds.isEmpty else { return }
        let url = ucAPIURL("/1/clouddrive/file/delete")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        ucSetCommonHeaders(&req, cookie: cookie)
        let body: [String: Any] = ["action_type": 2, "filelist": fileIds, "exclude_fids": []]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let _ = try? await ucSession.data(for: req)
        self.log("[CloudDrive] ✅ UC 已删除 \(fileIds.count) 个转存文件")
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
        let (data, _) = try await ucSession.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            if message.contains("非法token") || message.contains("token") {
                self.log("[CloudDrive] ⚠️ UC Cookie 已过期，请重新扫码登录")
            }
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

        let (data, _) = try await ucSession.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("UC v2/play 失败: \(message)")
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

    /// 使用 TV Token 列出云盘根目录文件，用于 stoken 失效时的兜底
    private func ucListFilesWithTVToken(tvToken: String, parentFid: String = "0") async throws -> [[String: Any]] {
        let signKey = "l3srvtd7p42l0d0x1u8d7yc8ye9kki4d"
        let clientId = "5acf882d27b74502b7040b0c65519aa7"
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let pathname = "/file"
        let tokenData = "GET&\(pathname)&\(timestamp)&\(signKey)"
        let xPanToken = SHA256.hash(data: Data(tokenData.utf8)).map { String(format: "%02x", $0) }.joined()
        let deviceId = UIDevice.current.identifierForVendor?.uuidString.replacingOccurrences(of: "-", with: "") ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let reqId = Insecure.MD5.hash(data: Data("\(deviceId)\(timestamp)".utf8)).map { String(format: "%02x", $0) }.joined()

        var components = URLComponents(string: "https://open-api-drive.uc.cn\(pathname)")!
        components.queryItems = [
            URLQueryItem(name: "method", value: "list"),
            URLQueryItem(name: "parent_fid", value: parentFid),
            URLQueryItem(name: "order_by", value: "3"),
            URLQueryItem(name: "desc", value: "1"),
            URLQueryItem(name: "category", value: ""),
            URLQueryItem(name: "source", value: ""),
            URLQueryItem(name: "ex_source", value: ""),
            URLQueryItem(name: "list_all", value: "0"),
            URLQueryItem(name: "page_size", value: "100"),
            URLQueryItem(name: "page_index", value: "0"),
            URLQueryItem(name: "access_token", value: tvToken),
            URLQueryItem(name: "app_ver", value: "1.6.8"),
            URLQueryItem(name: "device_id", value: deviceId),
            URLQueryItem(name: "device_brand", value: "Apple"),
            URLQueryItem(name: "platform", value: "tv"),
            URLQueryItem(name: "device_name", value: "iPhone"),
            URLQueryItem(name: "device_model", value: "iPhone"),
            URLQueryItem(name: "build_device", value: "iPhone"),
            URLQueryItem(name: "build_product", value: "iPhone"),
            URLQueryItem(name: "device_gpu", value: "Apple"),
            URLQueryItem(name: "activity_rect", value: "{}"),
            URLQueryItem(name: "channel", value: "UCTVOFFICIALWEB"),
            URLQueryItem(name: "req_id", value: reqId)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(clientId, forHTTPHeaderField: "x-pan-client-id")
        request.setValue(timestamp, forHTTPHeaderField: "x-pan-tm")
        request.setValue(xPanToken, forHTTPHeaderField: "x-pan-token")
        request.setValue("Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2004J7AC Build/UKQ1.231108.001) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await ucSession.data(for: request)
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        self.log("[CloudDrive] TV Token 列表响应: \(rawBody.prefix(200))")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let status = json["status"] as? Int, status == -1 {
            let info = json["error_info"] as? String ?? "status=-1"
            throw DriveError.noPlayURL("TV Token 列表失败：\(info)")
        }
        if let dataObj = json["data"] as? [String: Any],
           let files = dataObj["files"] as? [[String: Any]] {
            return files
        }
        return []
    }

    private func ucGetDownloadURL(fileId: String, cookie: String) async throws -> String {
        var request = URLRequest(url: ucAPIURL("/1/clouddrive/file/download"))
        request.httpMethod = "POST"
        ucSetCommonHeaders(&request, cookie: cookie)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fids": [fileId]])
        let (data, _) = try await ucSession.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        if let code = json["code"] as? Int, code != 0 {
            let message = json["message"] as? String ?? "code=\(code)"
            throw DriveError.noPlayURL("UC download_url 获取失败：\(message)")
        }
        // data 可能是数组 [{download_url: ...}] 也可能是字典 {download_url: ...}
        if let list = json["data"] as? [[String: Any]],
           let first = list.first,
           let url = first["download_url"] as? String {
            return url
        }
        if let dataObj = json["data"] as? [String: Any],
           let url = dataObj["download_url"] as? String {
            return url
        }
        return ""
    }

    private func ucGetPlayURLWithTVToken(fileId: String, tvToken: String) async throws -> String {
        let signKey = "l3srvtd7p42l0d0x1u8d7yc8ye9kki4d"
        let clientId = "5acf882d27b74502b7040b0c65519aa7"
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let pathname = "/file"
        // alist 用 GET 请求 /file 获取下载链接
        let tokenData = "GET&\(pathname)&\(timestamp)&\(signKey)"
        let xPanToken = SHA256.hash(data: Data(tokenData.utf8)).map { String(format: "%02x", $0) }.joined()
        let deviceId = UIDevice.current.identifierForVendor?.uuidString.replacingOccurrences(of: "-", with: "") ?? UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let reqId = Insecure.MD5.hash(data: Data("\(deviceId)\(timestamp)".utf8)).map { String(format: "%02x", $0) }.joined()

        var components = URLComponents(string: "https://open-api-drive.uc.cn\(pathname)")!
        components.queryItems = [
            URLQueryItem(name: "method", value: "download"),
            URLQueryItem(name: "group_by", value: "source"),
            URLQueryItem(name: "fid", value: fileId),
            URLQueryItem(name: "resolution", value: "low,normal,high,super,2k,4k"),
            URLQueryItem(name: "support", value: "dolby_vision"),
            URLQueryItem(name: "access_token", value: tvToken),
            URLQueryItem(name: "app_ver", value: "1.6.8"),
            URLQueryItem(name: "device_id", value: deviceId),
            URLQueryItem(name: "device_brand", value: "Apple"),
            URLQueryItem(name: "platform", value: "tv"),
            URLQueryItem(name: "device_name", value: "iPhone"),
            URLQueryItem(name: "device_model", value: "iPhone"),
            URLQueryItem(name: "build_device", value: "iPhone"),
            URLQueryItem(name: "build_product", value: "iPhone"),
            URLQueryItem(name: "device_gpu", value: "Apple"),
            URLQueryItem(name: "activity_rect", value: "{}"),
            URLQueryItem(name: "channel", value: "UCTVOFFICIALWEB"),
            URLQueryItem(name: "req_id", value: reqId)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(clientId, forHTTPHeaderField: "x-pan-client-id")
        request.setValue(timestamp, forHTTPHeaderField: "x-pan-tm")
        request.setValue(xPanToken, forHTTPHeaderField: "x-pan-token")
        request.setValue("Mozilla/5.0 (Linux; U; Android 13; zh-cn; M2004J7AC Build/UKQ1.231108.001) AppleWebKit/533.1 (KHTML, like Gecko) Mobile Safari/533.1", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await ucSession.data(for: request)
        let rawBody = String(data: data, encoding: .utf8) ?? "nil"
        self.log("[CloudDrive] TV Token API 响应: \(rawBody.prefix(300))")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DriveError.invalidResponse
        }
        // errno 10001 + status -1 = token 过期
        if let errno = json["errno"] as? Int, errno == 10001,
           let status = json["status"] as? Int, status == -1 {
            throw DriveError.noPlayURL("TV Token 已过期，请重新授权 TV")
        }
        if let status = json["status"] as? Int, status == -1 {
            let info = json["error_info"] as? String ?? json["message"] as? String ?? "status=-1"
            throw DriveError.noPlayURL("UCTV Token 获取播放地址失败：\(info)")
        }
        // alist 返回格式: { "data": { "download_url": "https://..." } }
        if let dataObj = json["data"] as? [String: Any] {
            if let url = dataObj["download_url"] as? String, !url.isEmpty { return url }
            // 兼容旧字段
            if let url = dataObj["url"] as? String, !url.isEmpty { return url }
            if let url = dataObj["play_url"] as? String, !url.isEmpty { return url }
            if let list = dataObj["video_list"] as? [[String: Any]] {
                for item in list {
                    if let info = item["video_info"] as? [String: Any],
                       let url = info["url"] as? String, !url.isEmpty {
                        return url
                    }
                }
            }
        }
        self.log("[CloudDrive] ⚠️ TV Token 响应解析失败: \(rawBody.prefix(500))")
        throw DriveError.noPlayURL("UCTV Token 返回中未找到播放地址")
    }

    // MARK: - 统一解析入口

    func resolvePlayURL(from shareURL: String) async throws -> PlayResult {
        let cleanURL = shareURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        self.log("[CloudDrive] resolvePlayURL 输入: \(cleanURL.prefix(80))")
        guard let driveType = Self.detectDrive(from: cleanURL) else {
            self.log("[CloudDrive] ❌ detectDrive 返回 nil")
            throw DriveError.invalidShareURL
        }
        self.log("[CloudDrive] ✅ detectDrive: \(driveType.rawValue)")

        let tokens = tokens(for: driveType)
        guard !tokens.isEmpty else {
            throw DriveError.tokenNotConfigured(driveType.displayName)
        }

        var lastError: Error?
        if driveType == .baidu, let pair = baiduTokenPair() {
            self.log("[CloudDrive] 🔄 尝试百度网盘 WebToken: \(pair.web.name)，PCSToken: \(pair.pcs?.name ?? "未配置")")
            return try await resolveBaiduPlayURL(
                shareURL: shareURL,
                bduss: pair.web.value,
                pcsCookie: pair.pcs?.value ?? ""
            )
        }

        for (index, token) in tokens.enumerated() {
            let label = tokens.count > 1 ? " [\(index + 1)/\(tokens.count)]" : ""
            self.log("[CloudDrive] 🔄 尝试 \(driveType.displayName) Token\(label): \(token.name)")
            do {
                let result: PlayResult
                switch driveType {
                case .ali:
                    result = try await resolveAliPlayURL(shareURL: shareURL, refreshToken: token.value)
                case .quark:
                    result = try await resolveQuarkPlayURLWithRetry(shareURL: shareURL, cookie: token.value)
                case .baidu:
                    result = try await resolveBaiduPlayURL(shareURL: shareURL, bduss: token.value)
                case .one15:
                    result = try await resolve115PlayURL(shareURL: shareURL, cid: token.value)
                case .uc:
                    result = try await resolveUCPlayURL(shareURL: shareURL, cookie: token.value)
                case .pan123:
                    result = try await resolve123PanPlayURL(shareURL: shareURL, token: token.value)
                case .pan139:
                    result = try await resolve139PanPlayURL(shareURL: shareURL, cookie: token.value)
                case .pan189:
                    result = try await resolve189PanPlayURL(shareURL: shareURL, cookie: token.value)
                }
                self.log("[CloudDrive] ✅ \(driveType.displayName) Token \"\(token.name)\" 成功")
                return result
            } catch {
                lastError = error
                self.log("[CloudDrive] ⚠️ \(driveType.displayName) Token \"\(token.name)\" 失败: \(error.localizedDescription)")
                if isLikelyAuthInvalid(error) {
                    CloudDriveAuthManager.shared.markInvalid(driveType, reason: error.localizedDescription)
                }
                continue
            }
        }

        let count = tokens.count
        self.log("[CloudDrive] ❌ 所有 \(count) 个 \(driveType.displayName) Token 均失败")
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
    case pan123 = "123云盘"
    case pan139 = "139云盘"
    case pan189 = "天翼云盘"
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

private struct AliDownloadURLResponse: Codable {
    let url: String?
    let expiration: String?
    let method: String?
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
