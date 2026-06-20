import Foundation
import GRDB

// MARK: - ZhanyuanSite

struct ZhanyuanSite: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int?
    var name: String
    var searchUrl: String
    var searchUA: String
    var playUA: String
    var websearchurl: String
    var searchname: String
    var searchid: String
    var searchpic: String
    var searchstarr: String
    var detaillist: String
    var detailxl: String
    var detailjs: String
    var detailjsurl: String
    var isActive: Bool
    var updatedAt: Int64

    static let defaultUA = "Mozilla/5.0 (Linux; Android 12; Redmi K30 Pro Build/SKQ1.220303.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/99.0.4844.88 Mobile Safari/537.36"

    init(id: Int? = nil,
         name: String,
         searchUrl: String,
         searchUA: String = defaultUA,
         playUA: String = "",
         websearchurl: String = "",
         searchname: String = "",
         searchid: String = "",
         searchpic: String = "",
         searchstarr: String = "",
         detaillist: String = "",
         detailxl: String = "",
         detailjs: String = "",
         detailjsurl: String = "",
         isActive: Bool = true,
         updatedAt: Int64 = Int64(Date().timeIntervalSince1970))
    {
        self.id = id
        self.name = name
        self.searchUrl = searchUrl
        self.searchUA = searchUA
        self.playUA = playUA
        self.websearchurl = websearchurl
        self.searchname = searchname
        self.searchid = searchid
        self.searchpic = searchpic
        self.searchstarr = searchstarr
        self.detaillist = detaillist
        self.detailxl = detailxl
        self.detailjs = detailjs
        self.detailjsurl = detailjsurl
        self.isActive = isActive
        self.updatedAt = updatedAt
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let searchUrl = Column(CodingKeys.searchUrl)
        static let searchUA = Column(CodingKeys.searchUA)
        static let playUA = Column(CodingKeys.playUA)
        static let websearchurl = Column(CodingKeys.websearchurl)
        static let searchname = Column(CodingKeys.searchname)
        static let searchid = Column(CodingKeys.searchid)
        static let searchpic = Column(CodingKeys.searchpic)
        static let searchstarr = Column(CodingKeys.searchstarr)
        static let detaillist = Column(CodingKeys.detaillist)
        static let detailxl = Column(CodingKeys.detailxl)
        static let detailjs = Column(CodingKeys.detailjs)
        static let detailjsurl = Column(CodingKeys.detailjsurl)
        static let isActive = Column(CodingKeys.isActive)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }

    // 用于 upsert：如果 name 已存在则更新，否则插入
    func doesExist(_ db: Database) throws -> Bool {
        return try ZhanyuanSite.filter(Columns.name == name).fetchCount(db) > 0
    }

    mutating func didInsert(with rowID: Int64, for column: String?) {
        id = Int(rowID)
    }
}

// MARK: - ApiYuanSite

struct ApiYuanSite: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int?
    var name: String
    var searchurl: String
    var searchua: String
    var detailurl: String
    var detailua: String
    var isActive: Bool

    init(id: Int? = nil,
         name: String,
         searchurl: String,
         searchua: String = "",
         detailurl: String = "",
         detailua: String = "",
         isActive: Bool = true)
    {
        self.id = id
        self.name = name
        self.searchurl = searchurl
        self.searchua = searchua
        self.detailurl = detailurl
        self.detailua = detailua
        self.isActive = isActive
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let searchurl = Column(CodingKeys.searchurl)
        static let searchua = Column(CodingKeys.searchua)
        static let detailurl = Column(CodingKeys.detailurl)
        static let detailua = Column(CodingKeys.detailua)
        static let isActive = Column(CodingKeys.isActive)
    }

    mutating func didInsert(with rowID: Int64, for column: String?) {
        id = Int(rowID)
    }
}

// MARK: - SubscriptionRecord

struct SubscriptionRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int?
    var dyname: String
    var dyurl: String
    var dyzz: String
    var lastSyncAt: Int64

    init(id: Int? = nil,
         dyname: String,
         dyurl: String,
         dyzz: String = "",
         lastSyncAt: Int64 = Int64(Date().timeIntervalSince1970))
    {
        self.id = id
        self.dyname = dyname
        self.dyurl = dyurl
        self.dyzz = dyzz
        self.lastSyncAt = lastSyncAt
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let dyname = Column(CodingKeys.dyname)
        static let dyurl = Column(CodingKeys.dyurl)
        static let dyzz = Column(CodingKeys.dyzz)
        static let lastSyncAt = Column(CodingKeys.lastSyncAt)
    }

    mutating func didInsert(with rowID: Int64, for column: String?) {
        id = Int(rowID)
    }
}

// MARK: - FavoriteRecord

struct FavoriteRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int?
    var name: String
    var laiyuan: String
    var imgurl: String
    var detailurl: String
    var detailua: String
    var xianlu: Int
    var jishu: Int
    var addedAt: Int64

    init(id: Int? = nil,
         name: String,
         laiyuan: String = "",
         imgurl: String = "",
         detailurl: String = "",
         detailua: String = "",
         xianlu: Int = 0,
         jishu: Int = 0,
         addedAt: Int64 = Int64(Date().timeIntervalSince1970))
    {
        self.id = id
        self.name = name
        self.laiyuan = laiyuan
        self.imgurl = imgurl
        self.detailurl = detailurl
        self.detailua = detailua
        self.xianlu = xianlu
        self.jishu = jishu
        self.addedAt = addedAt
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let laiyuan = Column(CodingKeys.laiyuan)
        static let imgurl = Column(CodingKeys.imgurl)
        static let detailurl = Column(CodingKeys.detailurl)
        static let detailua = Column(CodingKeys.detailua)
        static let xianlu = Column(CodingKeys.xianlu)
        static let jishu = Column(CodingKeys.jishu)
        static let addedAt = Column(CodingKeys.addedAt)
    }

    mutating func didInsert(with rowID: Int64, for column: String?) {
        id = Int(rowID)
    }
}

// MARK: - HistoryRecord

struct HistoryRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int?
    var name: String
    var laiyuan: String
    var imgurl: String
    var detailurl: String
    var detailua: String
    var xianlu: Int
    var jishu: Int
    var progress: Double
    var lastPlayedAt: Int64

    init(id: Int? = nil,
         name: String,
         laiyuan: String = "",
         imgurl: String = "",
         detailurl: String = "",
         detailua: String = "",
         xianlu: Int = 0,
         jishu: Int = 0,
         progress: Double = 0,
         lastPlayedAt: Int64 = Int64(Date().timeIntervalSince1970))
    {
        self.id = id
        self.name = name
        self.laiyuan = laiyuan
        self.imgurl = imgurl
        self.detailurl = detailurl
        self.detailua = detailua
        self.xianlu = xianlu
        self.jishu = jishu
        self.progress = progress
        self.lastPlayedAt = lastPlayedAt
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let laiyuan = Column(CodingKeys.laiyuan)
        static let imgurl = Column(CodingKeys.imgurl)
        static let detailurl = Column(CodingKeys.detailurl)
        static let detailua = Column(CodingKeys.detailua)
        static let xianlu = Column(CodingKeys.xianlu)
        static let jishu = Column(CodingKeys.jishu)
        static let progress = Column(CodingKeys.progress)
        static let lastPlayedAt = Column(CodingKeys.lastPlayedAt)
    }

    mutating func didInsert(with rowID: Int64, for column: String?) {
        id = Int(rowID)
    }
}

// MARK: - UserSetting

struct UserSetting: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var key: String
    var value: String
    var updatedAt: Int64

    // Identifiable 使用 key 作为 id
    var id: String { key }

    init(key: String,
         value: String = "",
         updatedAt: Int64 = Int64(Date().timeIntervalSince1970))
    {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }

    enum Columns {
        static let key = Column(CodingKeys.key)
        static let value = Column(CodingKeys.value)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }

    // PersistableRecord 的 primaryKey 覆盖
    static let databaseTableName = "settings"
}

// MARK: - JiexiSetting

struct JiexiSetting: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var bianma: String
    var zhuurl: String
    var beiurl: String

    // Identifiable 使用 bianma 作为 id
    var id: String { bianma }

    init(bianma: String,
         zhuurl: String = "",
         beiurl: String = "")
    {
        self.bianma = bianma
        self.zhuurl = zhuurl
        self.beiurl = beiurl
    }

    enum Columns {
        static let bianma = Column(CodingKeys.bianma)
        static let zhuurl = Column(CodingKeys.zhuurl)
        static let beiurl = Column(CodingKeys.beiurl)
    }

    static let databaseTableName = "jiexisetting"
}

// MARK: - SearchHistoryRecord

struct SearchHistoryRecord: Codable, Identifiable, FetchableRecord, PersistableRecord {
    var id: Int?
    var keyword: String
    var searchedAt: Int64

    init(id: Int? = nil,
         keyword: String,
         searchedAt: Int64 = Int64(Date().timeIntervalSince1970))
    {
        self.id = id
        self.keyword = keyword
        self.searchedAt = searchedAt
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let keyword = Column(CodingKeys.keyword)
        static let searchedAt = Column(CodingKeys.searchedAt)
    }

    mutating func didInsert(with rowID: Int64, for column: String?) {
        id = Int(rowID)
    }
}
