import Foundation
import GRDB

class DatabaseManager {
    static let shared = DatabaseManager()

    private var dbPool: DatabasePool!

    private init() {
        setupDatabase()
    }

    private func setupDatabase() {
        let fileManager = FileManager.default
        let appSupport = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dbURL = appSupport.appendingPathComponent("vbox.sqlite3")

        do {
            dbPool = try DatabasePool(path: dbURL.path)

            try migrator.migrate(dbPool)
            print("[DatabaseManager] 数据库初始化成功: \(dbURL.path)")
            
            // 首次启动时迁移 UserDefaults 中的旧订阅 URL
            migrateUserDefaultsIfNeeded()
        } catch {
            print("[DatabaseManager] 数据库初始化失败: \(error)")
        }
    }

    // MARK: - Migrator

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_createTables") { db in
            // zhanyuan 表
            try db.create(table: "zhanyuan") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("searchUrl", .text).notNull()
                t.column("searchUA", .text).notNull()
                    .defaults(to: "Mozilla/5.0 (Linux; Android 12; Redmi K30 Pro Build/SKQ1.220303.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/99.0.4844.88 Mobile Safari/537.36")
                t.column("playUA", .text).notNull().defaults(to: "")
                t.column("websearchurl", .text).notNull().defaults(to: "")
                t.column("searchname", .text).notNull().defaults(to: "")
                t.column("searchid", .text).notNull().defaults(to: "")
                t.column("searchpic", .text).notNull().defaults(to: "")
                t.column("searchstarr", .text).notNull().defaults(to: "")
                t.column("detaillist", .text).notNull().defaults(to: "")
                t.column("detailxl", .text).notNull().defaults(to: "")
                t.column("detailjs", .text).notNull().defaults(to: "")
                t.column("detailjsurl", .text).notNull().defaults(to: "")
                t.column("isActive", .boolean).notNull().defaults(to: true)
                t.column("updatedAt", .integer).notNull()
                t.uniqueKey(["name"])
            }

            // apiyuan 表
            try db.create(table: "apiyuan") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("searchurl", .text).notNull()
                t.column("searchua", .text).notNull().defaults(to: "")
                t.column("detailurl", .text).notNull().defaults(to: "")
                t.column("detailua", .text).notNull().defaults(to: "")
                t.column("isActive", .boolean).notNull().defaults(to: true)
                t.uniqueKey(["name"])
            }

            // subscription 表
            try db.create(table: "subscription") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("dyname", .text).notNull()
                t.column("dyurl", .text).notNull().unique()
                t.column("dyzz", .text).notNull().defaults(to: "")
                t.column("lastSyncAt", .integer).notNull()
            }

            // favorite 表
            try db.create(table: "favorite") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("laiyuan", .text).notNull().defaults(to: "")
                t.column("imgurl", .text).notNull().defaults(to: "")
                t.column("detailurl", .text).notNull().defaults(to: "")
                t.column("detailua", .text).notNull().defaults(to: "")
                t.column("xianlu", .integer).notNull().defaults(to: 0)
                t.column("jishu", .integer).notNull().defaults(to: 0)
                t.column("addedAt", .integer).notNull()
            }

            // history 表
            try db.create(table: "history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("laiyuan", .text).notNull().defaults(to: "")
                t.column("imgurl", .text).notNull().defaults(to: "")
                t.column("detailurl", .text).notNull().defaults(to: "")
                t.column("detailua", .text).notNull().defaults(to: "")
                t.column("xianlu", .integer).notNull().defaults(to: 0)
                t.column("jishu", .integer).notNull().defaults(to: 0)
                t.column("progress", .double).notNull().defaults(to: 0)
                t.column("lastPlayedAt", .integer).notNull()
            }

            // settings 表
            try db.create(table: "settings") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull().defaults(to: "")
                t.column("updatedAt", .integer).notNull()
            }

            // jiexisetting 表
            try db.create(table: "jiexisetting") { t in
                t.column("bianma", .text).primaryKey()
                t.column("zhuurl", .text).notNull().defaults(to: "")
                t.column("beiurl", .text).notNull().defaults(to: "")
            }

            // search_history 表
            try db.create(table: "search_history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("keyword", .text).notNull()
                t.column("searchedAt", .integer).notNull()
            }
        }

        return migrator
    }

    // MARK: - UserDefaults 数据迁移

    /// App 升级后首次启动，将 UserDefaults 中的旧订阅 URL 迁移到 SQLite
    private func migrateUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "vbox_sqlite_migration_done"
        guard !defaults.bool(forKey: migrationKey) else { return }

        // 读取旧订阅 URL 列表
        let urlsKey = "subscribed_config_urls"
        guard let oldURLs = defaults.stringArray(forKey: urlsKey), !oldURLs.isEmpty else {
            defaults.set(true, forKey: migrationKey)
            return
        }

        let now = Int64(Date().timeIntervalSince1970)
        var migratedCount = 0

        do {
            try dbPool.write { db in
                for url in oldURLs {
                    // 检查是否已存在
                    let existing = try SubscriptionRecord
                        .filter(SubscriptionRecord.Columns.dyurl == url)
                        .fetchOne(db)
                    if existing == nil {
                        // 从 URL 提取订阅名称
                        let name = (url as NSString).lastPathComponent
                            .replacingOccurrences(of: ".json", with: "")
                            .replacingOccurrences(of: ".txt", with: "")
                        let record = SubscriptionRecord(
                            dyname: name,
                            dyurl: url,
                            dyzz: "",
                            lastSyncAt: 0  // 标记为未同步，下次启动时会重新下载
                        )
                        try record.save(db)
                        migratedCount += 1
                    }
                }
            }
            print("[DatabaseManager] ✅ 迁移完成: \(migratedCount)/\(oldURLs.count) 个订阅 URL 已写入 SQLite")
        } catch {
            print("[DatabaseManager] ❌ 迁移失败: \(error)")
        }

        // 标记迁移完成
        defaults.set(true, forKey: migrationKey)
    }

    // MARK: - Zhanyuan CRUD

    func saveZhanyuanSites(_ sites: [ZhanyuanSite]) {
        do {
            try dbPool.write { db in
                for site in sites {
                    try site.save(db)
                }
            }
            print("[DatabaseManager] 保存 \(sites.count) 个 zhanyuan 站点")
        } catch {
            print("[DatabaseManager] 保存 zhanyuan 失败: \(error)")
        }
    }

    func queryActiveZhanyuanSites() -> [ZhanyuanSite] {
        do {
            return try dbPool.read { db in
                try ZhanyuanSite
                    .filter(ZhanyuanSite.Columns.isActive == true)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询 zhanyuan 失败: \(error)")
            return []
        }
    }

    func queryAllZhanyuanSites() -> [ZhanyuanSite] {
        do {
            return try dbPool.read { db in
                try ZhanyuanSite
                    .order(ZhanyuanSite.Columns.name.asc)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询全部 zhanyuan 失败: \(error)")
            return []
        }
    }

    func updateZhanyuanActive(name: String, isActive: Bool) {
        do {
            try dbPool.write { db in
                try ZhanyuanSite
                    .filter(ZhanyuanSite.Columns.name == name)
                    .updateAll(db, ZhanyuanSite.Columns.isActive.set(to: isActive))
            }
        } catch {
            print("[DatabaseManager] 更新 zhanyuan 状态失败: \(error)")
        }
    }

    // MARK: - ApiYuan CRUD

    func saveApiYuanSites(_ sites: [ApiYuanSite]) {
        do {
            try dbPool.write { db in
                for site in sites {
                    try site.save(db)
                }
            }
            print("[DatabaseManager] 保存 \(sites.count) 个 apiyuan 站点")
        } catch {
            print("[DatabaseManager] 保存 apiyuan 失败: \(error)")
        }
    }

    func queryActiveApiYuanSites() -> [ApiYuanSite] {
        do {
            return try dbPool.read { db in
                try ApiYuanSite
                    .filter(ApiYuanSite.Columns.isActive == true)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询 apiyuan 失败: \(error)")
            return []
        }
    }

    func queryAllApiYuanSites() -> [ApiYuanSite] {
        do {
            return try dbPool.read { db in
                try ApiYuanSite
                    .order(ApiYuanSite.Columns.name.asc)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询全部 apiyuan 失败: \(error)")
            return []
        }
    }

    func updateApiYuanActive(name: String, isActive: Bool) {
        do {
            try dbPool.write { db in
                try ApiYuanSite
                    .filter(ApiYuanSite.Columns.name == name)
                    .updateAll(db, ApiYuanSite.Columns.isActive.set(to: isActive))
            }
        } catch {
            print("[DatabaseManager] 更新 apiyuan 状态失败: \(error)")
        }
    }

    // MARK: - Subscription CRUD

    func saveSubscription(_ record: SubscriptionRecord) {
        do {
            try dbPool.write { db in
                try record.save(db)
            }
        } catch {
            print("[DatabaseManager] 保存订阅记录失败: \(error)")
        }
    }

    func querySubscriptions() -> [SubscriptionRecord] {
        do {
            return try dbPool.read { db in
                try SubscriptionRecord
                    .order(SubscriptionRecord.Columns.id.asc)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询订阅记录失败: \(error)")
            return []
        }
    }

    func updateSubscriptionSyncTime(dyurl: String, timestamp: Int64) {
        do {
            try dbPool.write { db in
                try SubscriptionRecord
                    .filter(SubscriptionRecord.Columns.dyurl == dyurl)
                    .updateAll(db, SubscriptionRecord.Columns.lastSyncAt.set(to: timestamp))
            }
        } catch {
            print("[DatabaseManager] 更新同步时间失败: \(error)")
        }
    }

    func deleteSubscription(dyurl: String) {
        do {
            try dbPool.write { db in
                try SubscriptionRecord
                    .filter(SubscriptionRecord.Columns.dyurl == dyurl)
                    .deleteAll(db)
            }
        } catch {
            print("[DatabaseManager] 删除订阅记录失败: \(error)")
        }
    }

    // MARK: - Favorite CRUD

    func addFavorite(_ record: FavoriteRecord) {
        do {
            try dbPool.write { db in
                try record.save(db)
            }
        } catch {
            print("[DatabaseManager] 添加收藏失败: \(error)")
        }
    }

    func removeFavorite(id: Int) {
        do {
            try dbPool.write { db in
                try FavoriteRecord
                    .filter(FavoriteRecord.Columns.id == id)
                    .deleteAll(db)
            }
        } catch {
            print("[DatabaseManager] 删除收藏失败: \(error)")
        }
    }

    func queryFavorites() -> [FavoriteRecord] {
        do {
            return try dbPool.read { db in
                try FavoriteRecord
                    .order(FavoriteRecord.Columns.addedAt.desc)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询收藏失败: \(error)")
            return []
        }
    }

    func isFavorite(detailurl: String, xianlu: Int, jishu: Int) -> Bool {
        do {
            return try dbPool.read { db in
                let count = try FavoriteRecord
                    .filter(FavoriteRecord.Columns.detailurl == detailurl)
                    .filter(FavoriteRecord.Columns.xianlu == xianlu)
                    .filter(FavoriteRecord.Columns.jishu == jishu)
                    .fetchCount(db)
                return count > 0
            }
        } catch {
            return false
        }
    }

    // MARK: - History CRUD

    func addOrUpdateHistory(_ record: HistoryRecord) {
        do {
            try dbPool.write { db in
                if let existing = try HistoryRecord
                    .filter(HistoryRecord.Columns.detailurl == record.detailurl)
                    .filter(HistoryRecord.Columns.xianlu == record.xianlu)
                    .filter(HistoryRecord.Columns.jishu == record.jishu)
                    .fetchOne(db)
                {
                    var updated = existing
                    updated.name = record.name
                    updated.laiyuan = record.laiyuan
                    updated.imgurl = record.imgurl
                    updated.detailua = record.detailua
                    updated.progress = record.progress
                    updated.lastPlayedAt = record.lastPlayedAt
                    try updated.update(db)
                } else {
                    try record.save(db)
                }
            }
        } catch {
            print("[DatabaseManager] 保存历史记录失败: \(error)")
        }
    }

    func queryHistory() -> [HistoryRecord] {
        do {
            return try dbPool.read { db in
                try HistoryRecord
                    .order(HistoryRecord.Columns.lastPlayedAt.desc)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询历史记录失败: \(error)")
            return []
        }
    }

    func deleteHistory(id: Int) {
        do {
            try dbPool.write { db in
                try HistoryRecord
                    .filter(HistoryRecord.Columns.id == id)
                    .deleteAll(db)
            }
        } catch {
            print("[DatabaseManager] 删除历史记录失败: \(error)")
        }
    }

    func clearHistory() {
        do {
            try dbPool.write { db in
                try HistoryRecord.deleteAll(db)
            }
        } catch {
            print("[DatabaseManager] 清空历史记录失败: \(error)")
        }
    }

    // MARK: - Settings CRUD

    func setSetting(key: String, value: String) {
        do {
            try dbPool.write { db in
                try UserSetting(
                    key: key,
                    value: value,
                    updatedAt: Int64(Date().timeIntervalSince1970)
                ).save(db, onConflict: .replace)
            }
        } catch {
            print("[DatabaseManager] 保存设置失败: \(error)")
        }
    }

    func getSetting(key: String) -> String? {
        do {
            return try dbPool.read { db in
                try UserSetting
                    .filter(UserSetting.Columns.key == key)
                    .fetchOne(db)?.value
            }
        } catch {
            print("[DatabaseManager] 读取设置失败: \(error)")
            return nil
        }
    }

    func deleteSetting(key: String) {
        do {
            try dbPool.write { db in
                try UserSetting
                    .filter(UserSetting.Columns.key == key)
                    .deleteAll(db)
            }
        } catch {
            print("[DatabaseManager] 删除设置失败: \(error)")
        }
    }

    // MARK: - JiexiSetting CRUD

    func saveJiexiSetting(_ record: JiexiSetting) {
        do {
            try dbPool.write { db in
                try record.save(db, onConflict: .replace)
            }
        } catch {
            print("[DatabaseManager] 保存解析设置失败: \(error)")
        }
    }

    func queryJiexiSettings() -> [JiexiSetting] {
        do {
            return try dbPool.read { db in
                try JiexiSetting.fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询解析设置失败: \(error)")
            return []
        }
    }

    func deleteJiexiSetting(bianma: String) {
        do {
            try dbPool.write { db in
                try JiexiSetting
                    .filter(JiexiSetting.Columns.bianma == bianma)
                    .deleteAll(db)
            }
        } catch {
            print("[DatabaseManager] 删除解析设置失败: \(error)")
        }
    }

    // MARK: - SearchHistory CRUD

    func addSearchHistory(keyword: String) {
        do {
            try dbPool.write { db in
                try SearchHistoryRecord(
                    keyword: keyword,
                    searchedAt: Int64(Date().timeIntervalSince1970)
                ).save(db)
            }
        } catch {
            print("[DatabaseManager] 保存搜索历史失败: \(error)")
        }
    }

    func querySearchHistory(limit: Int = 20) -> [SearchHistoryRecord] {
        do {
            return try dbPool.read { db in
                try SearchHistoryRecord
                    .order(SearchHistoryRecord.Columns.searchedAt.desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询搜索历史失败: \(error)")
            return []
        }
    }

    func clearSearchHistory() {
        do {
            try dbPool.write { db in
                try SearchHistoryRecord.deleteAll(db)
            }
        } catch {
            print("[DatabaseManager] 清空搜索历史失败: \(error)")
        }
    }
}
