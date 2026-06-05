import Foundation
import SwiftUI

/// 蜘蛛管理器 — 统一管理订阅源加载、蜘蛛引擎、数据获取
@MainActor
class SpiderManager: ObservableObject {
    
    static let shared = SpiderManager()
    
    @Published var categories: [VodCategory] = []
    @Published var homeVideos: [VodItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isInitialized = false
    @Published var subscribedSites: [String] = []
    @Published var savedURLs: [String] = []
    @Published var loadedSiteCount: Int = 0
    @Published var allSites: [SiteConfig] = []
    @Published var engineError: String?
    var enginesCount: Int { engines.count }
    
    private let subManager = SubscriptionManager()
    private var engines: [String: QJSSpiderEngine] = [:]
    
    private init() {
        savedURLs = subManager.configURLs
    }
    
    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true
        
        // 尝试加载 QuickJS 内置蜘蛛
        await loadBuiltinEngineIfNeeded()
        
        // 如果有已保存的订阅源，则加载
        if subManager.isLoaded {
            await loadSitesFromSubscription()
        }
        
        print("[SpiderManager] 初始化完成，引擎数: \(engines.count), 站点数: \(subManager.config?.sites.count ?? 0)")
    }
    
    /// 加载内置 QuickJS 蜘蛛引擎
    private func loadBuiltinEngineIfNeeded() async {
        guard engines["builtin"] == nil else { return }
        do {
            try await loadSpiderEngine(jsCode: getBuiltinSpiderJS())
            print("[SpiderManager] ✅ 内置蜘蛛加载成功")
        } catch {
            engineError = "蜘蛛加载失败: \(error.localizedDescription)"
            print("[SpiderManager] ❌ 内置蜘蛛加载失败: \(error.localizedDescription)")
        }
    }
    
    /// 获取内置蜘蛛 JS 代码 — 蜘蛛通过 http() 桥接调用原生网络
    private func getBuiltinSpiderJS() -> String {
        return """
function VideoDetail() { this.vod_id = ""; this.vod_name = ""; this.vod_pic = ""; this.vod_remarks = ""; }
function RepVideoList() { this.data = []; this.total = 0; this.error = ""; }

// req — http() 是同步阻塞的，直接取结果
function req(url, options) {
    var opts = options || {};
    var resp = JSON.parse(http(url, JSON.stringify({
        method: opts.method || 'GET',
        headers: opts.headers || {},
        data: opts.data || '',
        timeout: 5
    })));
    resp.data = resp.content;
    return resp;
}

var wooyun = {
    webSite: 'https://wooyun.tv',
    getHeaders: function() {
        return { Referer: this.webSite, 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36' };
    },
    search: function(keyword, page) {
        var back = new RepVideoList();
        if (!keyword) return JSON.stringify(back);
        try {
            var resp = req(this.webSite + '/api/proxy?url=%2Fmovie%2Fmedia%2Fsearch', {
                method: 'POST', headers: this.getHeaders(),
                data: JSON.stringify({ menuCodeList: [], pageIndex: String(page||1), pageSize: 10, searchKey: keyword, topCode: '' })
            });
            var json = JSON.parse(resp.data || '{}');
            var records = (json.data && json.data.records) || [];
            for (var i = 0; i < records.length; i++) {
                var r = records[i], v = new VideoDetail();
                v.vod_id = String(r.id||''); v.vod_name = r.title||''; v.vod_pic = r.posterUrlS3||r.posterUrl||'';
                v.vod_remarks = '乌云影视'; back.data.push(v);
            }
        } catch(e) { back.error = String(e); }
        return JSON.stringify(back);
    }
};

var _spider = {
    homeContent: function() { return JSON.stringify({ class: [], list: [] }); },
    searchContent: function(k, p) { return wooyun.search(k, p); },
    detailContent: function(i) { return JSON.stringify({ list: [] }); },
    playerContent: function(v,f,u) { return JSON.stringify({ parse: 0, url: u }); }
};
globalThis.__JS_SPIDER__ = _spider;
"""
    }
    
    func loadSubscribeConfig(from url: String) async {
        isLoading = true
        errorMessage = nil
        await subManager.loadConfig(from: url)
        if let error = subManager.errorMessage {
            errorMessage = error
            isLoading = false
            return
        }
        await loadSitesFromSubscription()
        savedURLs = subManager.configURLs
        isLoading = false
    }
    
    private func loadSitesFromSubscription() async {
        guard let config = subManager.config else {
            errorMessage = "订阅源配置为空"
            return
        }
        
        self.allSites = config.sites
        loadedSiteCount = allSites.count
        
        // 0. 先确保内置蜘蛛加载
        await loadBuiltinEngineIfNeeded()
        
        // 1. 尝试从订阅源的 spider 字段加载全局 JS 蜘蛛
        if let spiderURL = config.spider, spiderURL.hasPrefix("http") {
            do {
                let rawData = try await downloadRawData(url: spiderURL)
                if let snippet = String(data: rawData, encoding: .utf8),
                   snippet.count > 100,
                   snippet.contains("function ") || snippet.contains("var ") || snippet.contains("let ") || snippet.contains("const ") {
                    try await loadSpiderEngine(jsCode: snippet, key: "remote_spider")
                    print("[SpiderManager] ✅ 远程蜘蛛加载成功")
                } else {
                    print("[SpiderManager] spider URL 不是纯 JS（可能是 jar 包），使用内置蜘蛛")
                }
            } catch {
                print("[SpiderManager] spider URL 加载失败: \(error.localizedDescription)")
            }
        }
        
        // 2. 加载 type=3 的 JS 蜘蛛（每个站点一个引擎）
        var jsSpiderLoaded = 0
        var jsSpiderFailed = 0
        let jsSites = config.sites.filter { $0.type == 3 && $0.api != nil && !$0.api!.isEmpty && ($0.api!.hasPrefix("http://") || $0.api!.hasPrefix("https://")) }
        print("[SpiderManager] 发现 \(jsSites.count) 个 JS 蜘蛛站点")
        
        // 限制最多加载 10 个蜘蛛（避免内存爆炸）
        for site in jsSites.prefix(10) {
            guard let jsURL = site.api, let url = URL(string: jsURL) else { continue }
            let key = site.key.isEmpty ? site.name : site.key
            if engines[key] != nil { continue } // 已加载
            
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 15
                req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: req)
                if let jsCode = String(data: data, encoding: .utf8),
                   jsCode.count > 200,
                   (jsCode.contains("function ") || jsCode.contains("var ") || jsCode.contains("spider")) {
                    try await loadSpiderEngine(jsCode: jsCode, key: key)
                    jsSpiderLoaded += 1
                    print("[SpiderManager] ✅ JS蜘蛛加载成功: \(site.name) (\(key))")
                } else {
                    jsSpiderFailed += 1
                    print("[SpiderManager] ⚠️ JS蜘蛛内容无效: \(site.name)")
                }
            } catch {
                jsSpiderFailed += 1
                print("[SpiderManager] JS蜘蛛加载失败: \(site.name) - \(error.localizedDescription)")
            }
        }
        
        print("[SpiderManager] JS蜘蛛: 成功\(jsSpiderLoaded) 失败\(jsSpiderFailed), 总引擎: \(engines.count)")
        await loadHomeData()
    }
    
    /// 加载蜘蛛 JS 到引擎
    private func loadSpiderEngine(jsCode: String, key: String = "builtin") async throws {
        let engine = QJSSpiderEngine()
        engine.onLog = { msg in
            print("[SpiderEngine|\(key)] \(msg)")
            if msg.contains("❌") || msg.contains("异常") || msg.contains("失败") {
                Task { @MainActor in self.engineError = msg }
            }
        }
        try engine.loadScript(jsCode)
        if engine.registerSpider() {
            engines[key] = engine
            if !subscribedSites.contains(key) {
                subscribedSites.append(key)
            }
            engineError = nil
        } else {
            let err = "蜘蛛注册失败: __JS_SPIDER__ 未找到 (\(key))"
            engineError = err
            throw QJSError(message: err)
        }
    }
    
    private func downloadRawData(url: String) async throws -> Data {
        guard let urlObj = URL(string: url) else {
            throw QJSError(message: "无效URL: \(url)")
        }
        let (data, _) = try await URLSession.shared.data(from: urlObj)
        return data
    }
    
    private func loadSiteEngine(site: SiteConfig, jsURL: String) async throws {
        let engine = QJSSpiderEngine()
        let jsCode = try await downloadScript(url: jsURL)
        try engine.loadScript(jsCode)
        if engine.registerSpider() {
            engines[site.key] = engine
            if !subscribedSites.contains(site.key) {
                subscribedSites.append(site.key)
            }
            print("[SpiderManager] ✅ ext站点: \(site.name)")
        }
    }
    
    private func downloadScript(url: String) async throws -> String {
        guard let urlObj = URL(string: url) else {
            throw QJSError(message: "无效脚本URL: \(url)")
        }
        let (data, _) = try await URLSession.shared.data(from: urlObj)
        guard let script = String(data: data, encoding: .utf8) else {
            throw QJSError(message: "脚本编码错误")
        }
        return script
    }
    
    func loadHomeData() async {
        var videos: [VodItem] = []
        
        // 1. 尝试从 QuickJS 蜘蛛获取
        if !engines.isEmpty {
            for (key, engine) in engines {
                do {
                    let result = try engine.callHomeContent()
                    self.categories = result.class ?? []
                    if let list = result.list, !list.isEmpty {
                        videos.append(contentsOf: list)
                        print("[SpiderManager] 首页[\(key)]: \(list.count)视频")
                        if videos.count >= 20 { break }
                    }
                } catch {
                    print("[SpiderManager] 首页[\(key)]失败: \(error)")
                }
            }
        }
        
        // 2. 蜘蛛没数据，用热门关键词走 nativeSearch 填充首页
        if videos.isEmpty {
            print("[SpiderManager] 蜘蛛首页为空，用热门关键词拉取...")
            let hotKeywords = ["热播", "电影", "电视剧", "综艺", "动漫", "2026", "最新"]
            for kw in hotKeywords {
                let results = await nativeSearch(keyword: kw)
                videos.append(contentsOf: results)
                if videos.count >= 30 { break }
            }
        }
        
        // 去重
        var seen = Set<String>()
        videos = videos.filter { seen.insert($0.vodId.isEmpty ? $0.vodName : $0.vodId).inserted }
        
        await MainActor.run {
            self.homeVideos = videos
            if self.categories.isEmpty {
                self.categories = [
                    VodCategory(typeId: "movie", typeName: "电影"),
                    VodCategory(typeId: "tv", typeName: "电视剧"),
                    VodCategory(typeId: "variety", typeName: "综艺"),
                    VodCategory(typeId: "anime", typeName: "动漫")
                ]
            }
        }
        print("[SpiderManager] 首页: \(homeVideos.count)视频 \(categories.count)分类")
    }
    
    func search(keyword: String, pg: Int = 1) async -> [VodItem] {
        var allResults: [VodItem] = []
        var seenIds = Set<String>()
        
        // 先尝试加载内置蜘蛛
        if engines.isEmpty {
            await loadBuiltinEngineIfNeeded()
        }
        
        // 1. QuickJS 蜘蛛搜索
        for (key, engine) in engines {
            do {
                if let items = try engine.callSearchContent(keyword: keyword, pg: pg).list {
                    for var item in items {
                        // 标记来源蜘蛛名
                        if item.vodRemarks == nil || item.vodRemarks!.isEmpty {
                            item.vodRemarks = key
                        }
                        let id = item.vodId.isEmpty ? item.vodName : item.vodId
                        if !seenIds.contains(id) {
                            seenIds.insert(id)
                            allResults.append(item)
                        }
                    }
                    print("[SpiderManager] 蜘蛛搜索[\(key)]: \(items.count) 条")
                }
            } catch {
                engineError = "搜索出错: \(error.localizedDescription)"
                print("[SpiderManager] QuickJS 搜索失败[\(key)]: \(error)")
            }
        }
        
        // 2. 原生 HTTP 多源搜索（与 QuickJS 结果合并）
        let nativeResults = await nativeSearch(keyword: keyword)
        for item in nativeResults {
            let id = item.vodId.isEmpty ? item.vodName : item.vodId
            if !seenIds.contains(id) {
                seenIds.insert(id)
                allResults.append(item)
            }
        }
        
        print("[SpiderManager] 搜索完成: QuickJS+原生 共 \(allResults.count) 条")
        return allResults.isEmpty ? nativeResults : allResults
    }
    
    func getDetail(ids: String) async -> VodItem? {
        for (_, engine) in engines {
            do { return try engine.callDetailContent(ids: ids).list?.first } catch { continue }
        }
        return nil
    }
    
    func getPlayerContent(vodId: String, flag: String = "play", url: String) async -> PlayerContentResult? {
        for (_, engine) in engines {
            do { return try engine.callPlayerContent(vodId: vodId, flag: flag, url: url) } catch { continue }
        }
        return nil
    }
    
    func getSavedSubscriptionURLs() -> [String] { subManager.configURLs }
    func saveSubscriptionURL(_ url: String) {
        subManager.configURLs.append(url)
        UserDefaults.standard.set(subManager.configURLs, forKey: "subscribed_config_urls")
        savedURLs = subManager.configURLs
    }
    func removeSubscriptionURL(_ url: String) {
        subManager.removeURL(url)
        savedURLs = subManager.configURLs
    }
    
    /// 原生搜索 — 直接 HTTP 调可用 API，不经过 QuickJS
    func nativeSearch(keyword: String) async -> [VodItem] {
        var allResults: [VodItem] = []
        var seenIds = Set<String>()
        let encodedKW = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        
        // ====== 搜索源 1: 乌云影视 ======
        do {
            let url = URL(string: "https://wooyun.tv/api/proxy?url=%2Fmovie%2Fmedia%2Fsearch")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("https://wooyun.tv", forHTTPHeaderField: "Referer")
            req.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 10
            let body: [String: Any] = ["menuCodeList": [], "pageIndex": "1", "pageSize": 10, "searchKey": keyword, "topCode": ""]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj = json["data"] as? [String: Any],
               let records = dataObj["records"] as? [[String: Any]] {
                for item in records {
                    let vid = String(describing: item["id"] ?? "")
                    if !seenIds.contains(vid) {
                        seenIds.insert(vid)
                        allResults.append(VodItem(
                            vodId: vid,
                            vodName: (item["title"] as? String) ?? "",
                            vodPic: (item["posterUrlS3"] as? String) ?? (item["posterUrl"] as? String) ?? "",
                            vodRemarks: "乌云影视"
                        ))
                    }
                }
                print("[SpiderManager] 乌云影视: \(records.count) 条")
            }
        } catch {
            print("[SpiderManager] 乌云影视失败: \(error.localizedDescription)")
        }
        
        // ====== 搜索源 2: 非凡资源 ======
        if allResults.count < 20 {
            do {
                let ffURL = "http://ffzy1.tv/api.php/provide/vod/?ac=detail&wd=\(encodedKW)"
                if let url = URL(string: ffURL) {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 8
                    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                    let (data, _) = try await URLSession.shared.data(for: req)
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let list = json["list"] as? [[String: Any]] {
                        for item in list {
                            let vid = String(describing: item["vod_id"] ?? "")
                            if !seenIds.contains(vid) {
                                seenIds.insert(vid)
                                allResults.append(VodItem(
                                    vodId: vid,
                                    vodName: (item["vod_name"] as? String) ?? "",
                                    vodPic: (item["vod_pic"] as? String) ?? "",
                                    vodRemarks: "非凡资源",
                                    vodYear: item["vod_year"] as? String,
                                    vodDirector: item["vod_director"] as? String,
                                    vodActor: item["vod_actor"] as? String
                                ))
                            }
                        }
                        print("[SpiderManager] 非凡资源: \(list.count) 条")
                    }
                }
            } catch {
                print("[SpiderManager] 非凡资源失败: \(error.localizedDescription)")
            }
        }
        
        
        // ====== 搜索源 3: 虎牙采集 ======
        if allResults.count < 30 {
            do {
                let hyURL = "https://www.huyaapi.com/api.php/provide/vod/from/hym3u8?ac=detail&wd=\(encodedKW)"
                if let url = URL(string: hyURL) {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 8
                    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                    let (data, _) = try await URLSession.shared.data(for: req)
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let list = json["list"] as? [[String: Any]] {
                        for item in list {
                            let vid = String(describing: item["vod_id"] ?? "")
                            if !seenIds.contains(vid) {
                                seenIds.insert(vid)
                                allResults.append(VodItem(
                                    vodId: vid,
                                    vodName: (item["vod_name"] as? String) ?? "",
                                    vodPic: (item["vod_pic"] as? String) ?? "",
                                    vodRemarks: "虎牙采集",
                                    vodYear: item["vod_year"] as? String,
                                    vodDirector: item["vod_director"] as? String,
                                    vodActor: item["vod_actor"] as? String
                                ))
                            }
                        }
                        print("[SpiderManager] 虎牙采集: \(list.count) 条")
                    }
                }
            } catch {
                print("[SpiderManager] 虎牙采集失败: \(error.localizedDescription)")
            }
        }
        
        // ====== 搜索源 4: 火狐采集 ======
        if allResults.count < 30 {
            do {
                let hhURL = "https://hhzyapi.com/api.php/provide/vod/?ac=detail&wd=\(encodedKW)"
                if let url = URL(string: hhURL) {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 8
                    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                    let (data, _) = try await URLSession.shared.data(for: req)
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let list = json["list"] as? [[String: Any]] {
                        for item in list {
                            let vid = String(describing: item["vod_id"] ?? "")
                            if !seenIds.contains(vid) {
                                seenIds.insert(vid)
                                allResults.append(VodItem(
                                    vodId: vid,
                                    vodName: (item["vod_name"] as? String) ?? "",
                                    vodPic: (item["vod_pic"] as? String) ?? "",
                                    vodRemarks: "火狐采集",
                                    vodYear: item["vod_year"] as? String,
                                    vodDirector: item["vod_director"] as? String,
                                    vodActor: item["vod_actor"] as? String
                                ))
                            }
                        }
                        print("[SpiderManager] 火狐采集: \(list.count) 条")
                    }
                }
            } catch {
                print("[SpiderManager] 火狐采集失败: \(error.localizedDescription)")
            }
        }
        
        print("[SpiderManager] nativeSearch 总计 \(allResults.count) 条")
        return allResults
    }
    
    /// 通过订阅源的 type=1 站点获取详情+播放地址
    /// 先用 ids 查，失败则用 name 搜索匹配
    func nativeDetail(ids: String, name: String? = nil) async -> VodItem? {
        let apiSites = subManager.apiSites
        // 如果 apiSites 为空，降级用 allSites 中的 type=1 站点
        let detailSites = apiSites.isEmpty 
            ? allSites.filter { $0.type == 1 && $0.api != nil && !$0.api!.isEmpty } 
            : apiSites
        if detailSites.isEmpty { 
            print("[SpiderManager] nativeDetail 失败: 无可用的 type=1 站点")
            return nil 
        }
        print("[SpiderManager] nativeDetail: ids=\(ids), name=\(name ?? "nil"), 可用站点=\(detailSites.count)个")
        
        for site in detailSites {
            guard let siteApi = site.api, !siteApi.isEmpty else { continue }
            let api = siteApi.hasSuffix("/") ? String(siteApi.dropLast()) : siteApi
            
            // 先尝试用 ids
            if let detailURL = URL(string: "\(api)?ac=videolist&ids=\(ids)") {
                if let result = await fetchDetail(url: detailURL, siteName: site.name) {
                    return result
                }
            }
            
            // ids 失败，用名称搜索
            if let n = name, !n.isEmpty,
               let encN = n.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let searchURL = URL(string: "\(api)?ac=detail&wd=\(encN)") {
                if let result = await fetchDetailFromSearchList(url: searchURL, siteName: site.name, targetName: n) {
                    return result
                }
            }
        }
        print("[SpiderManager] nativeDetail 全部站点均失败")
        return nil
    }
    
    private func fetchDetail(url: URL, siteName: String) async -> VodItem? {
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["list"] as? [[String: Any]],
               let first = list.first {
                // 打印完整字段名以便调试
                print("[SpiderManager] nativeDetail(ids) \(siteName) 第一条keys: \(first.keys.sorted())")
                let item = Self.makeVodItem(from: first, siteName: siteName)
                print("[SpiderManager] nativeDetail(ids) \(siteName): vodPlayUrl=\(item.vodPlayUrl?.prefix(30) ?? \"nil\"), vodPlayFrom=\(item.vodPlayFrom?.prefix(30) ?? \"nil\")")
                return item
            } else {
                if let rawStr = String(data: data, encoding: .utf8) {
                    let preview = String(rawStr.prefix(200))
                    print("[SpiderManager] nativeDetail(ids) \(siteName): 原始响应(前200): \(preview)")
                }
            }
        } catch {
            print("[SpiderManager] nativeDetail(ids) \(siteName) 失败: \(error.localizedDescription)")
        }
        return nil
    }
    
    private func fetchDetailFromSearchList(url: URL, siteName: String, targetName: String) async -> VodItem? {
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["list"] as? [[String: Any]] {
                // 按名称匹配
                for item in list {
                    let itemName = (item["vod_name"] as? String) ?? ""
                    if itemName.contains(targetName) || targetName.contains(itemName) {
                        let vod = Self.makeVodItem(from: item, siteName: siteName)
                        print("[SpiderManager] nativeDetail(name) 匹配成功: \(siteName)")
                        return vod
                    }
                }
                print("[SpiderManager] nativeDetail(name) \(siteName): 搜索到\(list.count)条但无名称匹配或无播放地址")
            }
        } catch {
            print("[SpiderManager] nativeDetail(name) \(siteName) 失败: \(error.localizedDescription)")
        }
        return nil
    }
    
    private static func makeVodItem(from dict: [String: Any], siteName: String) -> VodItem {
        VodItem(
            vodId: String(describing: dict["vod_id"] ?? ""),
            vodName: (dict["vod_name"] as? String) ?? "",
            vodPic: (dict["vod_pic"] as? String) ?? "",
            vodRemarks: siteName,
            vodYear: dict["vod_year"] as? String,
            vodDirector: dict["vod_director"] as? String,
            vodActor: dict["vod_actor"] as? String,
            vodContent: dict["vod_content"] as? String,
            vodPlayFrom: dict["vod_play_from"] as? String,
            vodPlayUrl: dict["vod_play_url"] as? String
        )
    }
}

