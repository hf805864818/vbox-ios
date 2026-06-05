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
    private var engines: [String: JSSpiderEngine] = [:]

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
        let engine = JSSpiderEngine()
        engine.onLog = { msg in
            print("[SpiderEngine|\(key)] \(msg)")
            if msg.contains("❌") || msg.contains("异常") || msg.contains("失败") {
                Task { @MainActor in self.engineError = msg }
            }
        }
        // 注入 TVBox 标准模板库（模板.js、net.js）
        try await injectSpiderLibraries(engine: engine)
        try engine.loadScript(jsCode)
        // 尝试多种蜘蛛注册方式
        if engine.isSpiderReady {
            engines[key] = engine
            if !subscribedSites.contains(key) { subscribedSites.append(key) }
            engineError = nil
            print("[SpiderManager] ✅ 蜘蛛就绪: \(key)")
        } else {
            do {
                try engine.registerSpider()
                engines[key] = engine
                if !subscribedSites.contains(key) { subscribedSites.append(key) }
                engineError = nil
                print("[SpiderManager] ✅ 蜘蛛注册成功: \(key)")
            } catch {
                let err = "蜘蛛注册失败 (\(key)): \(error.localizedDescription)"
                engineError = err
                throw JSError(message: err)
            }
        }
    }

    /// 注入 TVBox 标准 JS 库（模板引擎、网络桥接等）
    private func injectSpiderLibraries(engine: JSSpiderEngine) async throws {
        // 1. net.js — 同步/异步 HTTP 请求封装
        try engine.loadLibrary("""
        let req = (url, options) => http(url, Object.assign({ async: false }, options));
        """)
        // 2. 模板引擎 — 如果 Bundle 中有模板.js 则加载
        if let tmplPath = Bundle.main.path(forResource: "模板", ofType: "js"),
           let tmplJs = try? String(contentsOfFile: tmplPath, encoding: .utf8) {
            try engine.loadLibrary(tmplJs)
            print("[SpiderManager] ✅ 模板引擎已注入")
        }
        print("[SpiderManager] ✅ JS 库注入完成")
    }

    private func downloadRawData(url: String) async throws -> Data {
        guard let urlObj = URL(string: url) else {
            throw JSError(message: "无效URL: \(url)")
        }
        let (data, _) = try await URLSession.shared.data(from: urlObj)
        return data
    }

    private func loadSiteEngine(site: SiteConfig, jsURL: String) async throws {
        let engine = JSSpiderEngine()
        try await injectSpiderLibraries(engine: engine)
        try await engine.loadScriptFromURL(jsURL)
        if engine.isSpiderReady {
            engines[site.key] = engine
            if !subscribedSites.contains(site.key) { subscribedSites.append(site.key) }
            print("[SpiderManager] ✅ ext站点: \(site.name)")
        } else {
            do {
                try engine.registerSpider()
                engines[site.key] = engine
                if !subscribedSites.contains(site.key) { subscribedSites.append(site.key) }
                print("[SpiderManager] ✅ ext站点(注册): \(site.name)")
            } catch {
                print("[SpiderManager] ❌ ext站点失败: \(site.name): \(error)")
            }
        }
    }

    private func downloadScript(url: String) async throws -> String {
        guard let urlObj = URL(string: url) else {
            throw JSError(message: "无效脚本URL: \(url)")
        }
        let (data, _) = try await URLSession.shared.data(from: urlObj)
        guard let script = String(data: data, encoding: .utf8) else {
            throw JSError(message: "脚本编码错误")
        }
        return script
    }

    func loadHomeData() async {
        var videos: [VodItem] = []

        print("[SpiderManager] ========== 开始加载首页数据 ==========")
        print("[SpiderManager] 可用蜘蛛引擎: \(engines.count)个")
        print("[SpiderManager] 可用API站点: \(allSites.filter { $0.api?.hasPrefix("http") ?? false }.count)个")

        // 1. 尝试从 QuickJS 蜘蛛获取
        if !engines.isEmpty {
            print("[SpiderManager] 尝试从蜘蛛引擎获取首页数据...")
            for (key, engine) in engines {
                do {
                    print("[SpiderManager] 调用蜘蛛引擎[\(key)]...")
                    let result = try engine.callHomeContent()
                    print("[SpiderManager] 蜘蛛[\(key)]返回分类: \(result.class?.count ?? 0)个, 列表: \(result.list?.count ?? 0)个")

                    if let categories = result.class, !categories.isEmpty {
                        self.categories = categories
                    }

                    if let list = result.list, !list.isEmpty {
                        videos.append(contentsOf: list)
                        print("[SpiderManager] ✅ 首页[\(key)]: \(list.count)视频")
                        if videos.count >= 20 {
                            print("[SpiderManager] 蜘蛛数据已足够，停止加载")
                            break
                        }
                    }
                } catch {
                    print("[SpiderManager] ❌ 首页[\(key)]失败: \(error)")
                }
            }
        } else {
            print("[SpiderManager] ⚠️ 没有可用的蜘蛛引擎")
        }

        // 2. 蜘蛛没数据，用热门关键词走 nativeSearch 填充首页
        if videos.isEmpty {
            print("[SpiderManager] ⚠️ 蜘蛛首页为空，使用热门关键词通过nativeSearch拉取数据...")
            let hotKeywords = [
                "热播", "电影", "电视剧", "综艺", "动漫", "2026", "最新",
                "热门", "高分", "经典", "动作", "喜剧", "爱情", "科幻",
                "悬疑", "犯罪", "战争", "古装", "现代", "都市"
            ]

            for (index, kw) in hotKeywords.enumerated() {
                print("[SpiderManager] [\(index+1)/\(hotKeywords.count)] 搜索关键词: \(kw)")
                let results = await nativeSearch(keyword: kw)
                print("[SpiderManager] 热门关键词[\(kw)]: \(results.count)条")
                videos.append(contentsOf: results)

                if videos.count >= 50 {
                    print("[SpiderManager] ✅ 已收集\(videos.count)条视频，停止搜索")
                    break
                }

                // 避免请求过快
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5秒延迟
            }
        } else {
            print("[SpiderManager] ✅ 蜘蛛数据已收集\(videos.count)条")
        }

        // 去重
        var seen = Set<String>()
        let originalCount = videos.count
        videos = videos.filter { seen.insert($0.vodId.isEmpty ? $0.vodName : $0.vodId).inserted }
        print("[SpiderManager] 去重前: \(originalCount)条, 去重后: \(videos.count)条")

        await MainActor.run {
            self.homeVideos = videos
            if self.categories.isEmpty {
                print("[SpiderManager] 使用默认分类")
                self.categories = [
                    VodCategory(typeId: "movie", typeName: "电影"),
                    VodCategory(typeId: "tv", typeName: "电视剧"),
                    VodCategory(typeId: "variety", typeName: "综艺"),
                    VodCategory(typeId: "anime", typeName: "动漫"),
                    VodCategory(typeId: "documentary", typeName: "纪录片"),
                    VodCategory(typeId: "live", typeName: "直播")
                ]
            }
            print("[SpiderManager] ========== 首页数据加载完成 ==========")
            print("[SpiderManager] 最终结果: \(videos.count)视频, \(categories.count)分类")
        }
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
                        if item.vodRemarks == nil || item.vodRemarks?.isEmpty == true {
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

        // 2. 原生 HTTP 多源搜索（遍历订阅源站点 + 硬编码兜底）
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

    /// 通过引擎获取详情，失败时回退到原生 API 详情
    func getDetail(ids: String, name: String? = nil) async -> VodItem? {
        // 1. 先尝试所有引擎
        for (_, engine) in engines {
            do {
                if let item = try engine.callDetailContent(ids: ids).list?.first {
                    return item
                }
            } catch { continue }
        }
        // 2. 引擎全部失败，回退到原生 API
        print("[SpiderManager] getDetail 引擎全部失败，回退到 nativeDetail")
        return await nativeDetail(ids: ids, name: name)
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
    /// 先遍历订阅源中的 type=1/0 站点，再用硬编码采集站兜底
    func nativeSearch(keyword: String) async -> [VodItem] {
        var allResults: [VodItem] = []
        var seenIds = Set<String>()
        let encodedKW = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword

        // ====== 搜索源 0: 遍历订阅源 type=1/0 站点 ======
        var searchSites = subManager.allSites.filter { ($0.type == 1 || $0.type == 0) && ($0.api?.isEmpty == false) }
        // 如果没有订阅源站点，用硬编码的兜底
        if searchSites.isEmpty {
            searchSites = [
                SiteConfig(key: "ffzy", name: "非凡资源", type: 1, api: "http://ffzy1.tv/api.php/provide/vod/"),
                SiteConfig(key: "huya", name: "虎牙采集", type: 1, api: "https://www.huyaapi.com/api.php/provide/vod/from/hym3u8"),
                SiteConfig(key: "hhzy", name: "火狐采集", type: 1, api: "https://hhzyapi.com/api.php/provide/vod/"),
                SiteConfig(key: "ayun", name: "奥运资源", type: 1, api: "https://www.ayunapi.com/api.php/provide/vod/"),
                SiteConfig(key: "kuaibo", name: "快播资源", type: 1, api: "https://www.kuaibozy.com/api.php/provide/vod/"),
                SiteConfig(key: "maotai", name: "茅台资源", type: 1, api: "https://caiji.maotaizy.cc/api.php/provide/vod/"),
                SiteConfig(key: "ruyi", name: "如意资源", type: 1, api: "https://cj.rycjapi.com/api.php/provide/vod/"),
                SiteConfig(key: "jisu", name: "极速资源", type: 1, api: "https://jszyapi.com/api.php/provide/vod/"),
                SiteConfig(key: "baofeng", name: "暴风资源", type: 1, api: "https://iqiyizyapi.com/api.php/provide/vod/"),
            ]
        }

        // 遍历每个站点搜索
        print("[SpiderManager] nativeSearch 共有 \(searchSites.count) 个 API 站点")
        for site in searchSites.prefix(20) {  // 最多搜20个防止太慢
            guard let siteApi = site.api, !siteApi.isEmpty else { continue }
            let api = siteApi.hasSuffix("/") ? String(siteApi.dropLast()) : siteApi
            let searchURL = "\(api)?ac=detail&wd=\(encodedKW)"

            do {
                if let url = URL(string: searchURL) {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 6
                    req.setValue("Mozilla/5.0 (Windows NT 10.0; WOW64; rv:45.0) Gecko/20100101 Firefox/45.0", forHTTPHeaderField: "User-Agent")
                    let (data, _) = try await URLSession.shared.data(for: req)
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let list = json["list"] as? [[String: Any]] {
                        var newCount = 0
                        for item in list {
                            let vid = String(describing: item["vod_id"] ?? "")
                            if !seenIds.contains(vid) {
                                seenIds.insert(vid)
                                newCount += 1
                                allResults.append(VodItem(
                                    vodId: vid,
                                    vodName: (item["vod_name"] as? String) ?? "",
                                    vodPic: (item["vod_pic"] as? String) ?? "",
                                    vodRemarks: site.name,
                                    vodYear: item["vod_year"] as? String,
                                    vodDirector: item["vod_director"] as? String,
                                    vodActor: item["vod_actor"] as? String
                                ))
                            }
                        }
                        print("[SpiderManager] \(site.name): \(list.count) 条 (\(newCount) 新增)")
                    }
                }
            } catch {
                print("[SpiderManager] \(site.name) 搜索失败: \(error.localizedDescription)")
            }
        }

        // ====== 搜索源 1: 乌云影视（独立 API） ======
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

        // ====== 搜索源 5: 奥运资源 ======
        if allResults.count < 40 {
            do {
                let ayURL = "https://www.ayunapi.com/api.php/provide/vod/?ac=detail&wd=\(encodedKW)"
                if let url = URL(string: ayURL) {
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
                                    vodRemarks: "奥运资源",
                                    vodYear: item["vod_year"] as? String,
                                    vodDirector: item["vod_director"] as? String,
                                    vodActor: item["vod_actor"] as? String
                                ))
                            }
                        }
                        print("[SpiderManager] 奥运资源: \(list.count) 条")
                    }
                }
            } catch {
                print("[SpiderManager] 奥运资源失败: \(error.localizedDescription)")
            }
        }

        // ====== 搜索源 6: 快播资源 ======
        if allResults.count < 50 {
            do {
                let kbURL = "https://www.kuaibozy.com/api.php/provide/vod/?ac=detail&wd=\(encodedKW)"
                if let url = URL(string: kbURL) {
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
                                    vodRemarks: "快播资源",
                                    vodYear: item["vod_year"] as? String,
                                    vodDirector: item["vod_director"] as? String,
                                    vodActor: item["vod_actor"] as? String
                                ))
                            }
                        }
                        print("[SpiderManager] 快播资源: \(list.count) 条")
                    }
                }
            } catch {
                print("[SpiderManager] 快播资源失败: \(error.localizedDescription)")
            }
        }

        print("[SpiderManager] nativeSearch 总计 \(allResults.count) 条")
        return allResults
    }

    /// 通过订阅源的 type=1 站点获取详情+播放地址
    /// 先用 ids 查，失败则用 name 搜索匹配
    func nativeDetail(ids: String, name: String? = nil) async -> VodItem? {
        let apiSites = subManager.apiSites
        // 如果 apiSites 为空，降级用 allSites 中的 type=1 或 type=0 站点
        var detailSites = apiSites.isEmpty
            ? allSites.filter { ($0.type == 1 || $0.type == 0) && ($0.api?.isEmpty == false) }
            : apiSites

        // 如果站点列表还是空的，用硬编码的采集站作为兜底
        if detailSites.isEmpty {
            print("[SpiderManager] nativeDetail 无订阅源站点，使用内置采集站兜底")
            detailSites = [
                SiteConfig(key: "hhzy", name: "火狐采集", type: 1, api: "https://hhzyapi.com/api.php/provide/vod/"),
                SiteConfig(key: "kuaibo", name: "快播资源", type: 1, api: "https://www.kuaibozy.com/api.php/provide/vod/"),
                SiteConfig(key: "ayun", name: "奥运资源", type: 1, api: "https://www.ayunapi.com/api.php/provide/vod/"),
                SiteConfig(key: "huya", name: "虎牙采集", type: 1, api: "https://www.huyaapi.com/api.php/provide/vod/from/hym3u8"),
                SiteConfig(key: "feifan", name: "非凡资源", type: 1, api: "http://ffzy1.tv/api.php/provide/vod/"),
                SiteConfig(key: "maotai", name: "茅台资源", type: 1, api: "https://caiji.maotaizy.cc/api.php/provide/vod/"),
                SiteConfig(key: "ruyi", name: "如意资源", type: 1, api: "https://cj.rycjapi.com/api.php/provide/vod/"),
                SiteConfig(key: "jisu", name: "极速资源", type: 1, api: "https://jszyapi.com/api.php/provide/vod/"),
                SiteConfig(key: "baofeng", name: "暴风资源", type: 1, api: "https://iqiyizyapi.com/api.php/provide/vod/"),
            ]
        }

        if detailSites.isEmpty {
            print("[SpiderManager] nativeDetail 失败: 无可用的 type=1 站点")
            print("[SpiderManager] 可用站点总数: \(allSites.count)")
            print("[SpiderManager] apiSites: \(apiSites.count)")
            return nil
        }

        print("[SpiderManager] nativeDetail: ids=\(ids), name=\(name ?? "nil"), 可用站点=\(detailSites.count)个")

        for site in detailSites {
            guard let siteApi = site.api, !siteApi.isEmpty else { continue }
            let api = siteApi.hasSuffix("/") ? String(siteApi.dropLast()) : siteApi

            // 尝试多种API格式
            let apiFormats = [
                "\(api)?ac=videolist&ids=\(ids)",
                "\(api)?ac=detail&ids=\(ids)",
                "\(api)?ac=videolist&ids=\(ids)&pg=1"
            ]

            for format in apiFormats {
                if let url = URL(string: format) {
                    print("[SpiderManager] 尝试API格式: \(format)")
                    if let result = await fetchDetail(url: url, siteName: site.name) {
                        print("[SpiderManager] ✅ nativeDetail 成功: \(site.name)")
                        return result
                    }
                }
            }

            // ids 失败，用名称搜索
            if let n = name, !n.isEmpty,
               let encN = n.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let searchURL = URL(string: "\(api)?ac=detail&wd=\(encN)") {
                if let result = await fetchDetailFromSearchList(url: searchURL, siteName: site.name, targetName: n) {
                    print("[SpiderManager] ✅ nativeDetail 名称搜索成功: \(site.name)")
                    return result
                }
            }
        }
        print("[SpiderManager] ❌ nativeDetail 全部站点均失败")
        return nil
    }

// 解析器体系 - 将HTML播放页解析为视频直链
    func parsePlayUrl(from playPageUrl: String) async -> String? {
        // 1. 检查是否已经是直链
        if playPageUrl.hasSuffix(".m3u8") || playPageUrl.hasSuffix(".mp4") {
            return playPageUrl
        }

        print("[SpiderManager] 开始解析播放页: \(playPageUrl.prefix(60))...")

        // 2. 优先使用订阅源的解析器
        if !subManager.parses.isEmpty {
            print("[SpiderManager] 使用订阅源解析器，共(subManager.parses.count)个")
            for (idx, parse) in subManager.parses.enumerated() {
                print("[SpiderManager] [\(idx+1)/\(subManager.parses.count)] 尝试：(parse.name) - (parse.url)")
                if let parsedUrl = await tryParser(parse.url, url: playPageUrl) {
                    print("[SpiderManager] ✅ 订阅源解析器成功：(parse.name)")
                    print("[SpiderManager] 解析结果：(parsedUrl.prefix(80)...")
                    return parsedUrl
                }
            }
        }

        // 3. 使用公共解析器兜底
        print("[SpiderManager] 订阅源解析器失败，尝试公共解析器...")
        let parsers = [
            "https://jx.xmflv.com/?url=",
            "https://jx.quankan.app/?url=",
            "https://jx.aidouer.net/?url=",
            "https://jx.m3u8.tv/jiexi/?url=",
            "https://jx.jsonplayer.com/api/?url="
        ]

        for parser in parsers {
            if let parsedUrl = await tryParser(parser, url: playPageUrl) {
                print("[SpiderManager] ✅ 解析器成功: \(parser)")
                print("[SpiderManager] 解析结果: \(parsedUrl.prefix(80))...")
                return parsedUrl
            }
        }

        print("[SpiderManager] ❌ 所有解析器均失败")
        return nil
    }

    private func tryParser(_ parserBase: String, url: String) async -> String? {
        let parseUrl = "\(parserBase)\(url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)"

        guard let requestUrl = URL(string: parseUrl) else { return nil }

        do {
            var request = URLRequest(url: requestUrl)
            request.timeoutInterval = 8
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

            let (data, _) = try await URLSession.shared.data(for: request)

            // 尝试从响应中提取m3u8/mp4链接
            if let responseStr = String(data: data, encoding: .utf8) {
                // 正则匹配视频链接
                let patterns = [
                    "https?://[^\\s\"'<>]+\\.m3u8[^\\s\"'<>]*",
                    "https?://[^\\s\"'<>]+\\.mp4[^\\s\"'<>]*",
                    "\"url\":\\s*\"([^\"]+)\""
                ]

                for pattern in patterns {
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let match = regex.firstMatch(in: responseStr, range: NSRange(responseStr.startIndex..., in: responseStr)) {

                        let result = (responseStr as NSString).substring(with: match.range(at: match.numberOfRanges - 1))

                        // 清理JSON格式的URL
                        if result.hasPrefix("\"") && result.hasSuffix("\"") {
                            let cleaned = String(result.dropFirst().dropLast())
                            if cleaned.hasPrefix("http") {
                                return cleaned
                            }
                        } else if result.hasPrefix("http") {
                            return result
                        }
                    }
                }
            }
        } catch {
            print("[SpiderManager] 解析器请求失败: \(error.localizedDescription)")
        }

        return nil
    }

    // 从vodPlayUrl中提取第一集URL
    private func extractFirstPlayableUrl(from vodPlayUrl: String?) -> String? {
        guard let playUrl = vodPlayUrl, !playUrl.isEmpty else {
            return nil
        }

        // 格式：第1集$http://...#第2集$http://...
        let episodes = playUrl.components(separatedBy: "#")

        for episode in episodes {
            // 按 $ 分割，取最后一个（URL部分）
            let parts = episode.components(separatedBy: "$")
            if let urlPart = parts.last {
                // 提取 URL
                if let urlRange = urlPart.range(of: "http") {
                    var url = String(urlPart[urlRange.lowerBound...])

                    // 清理可能的尾部字符，但保留查询参数
                    let stopChars = ["#", "\n", "\r", " ", "$$", "$"]
                    for char in stopChars {
                        if let endRange = url.range(of: char) {
                            url = String(url[..<endRange.lowerBound])
                        }
                    }

                    // 验证是否为有效的视频URL
                    let isVideoUrl = url.contains(".m3u8") ||
                                    url.contains(".mp4") ||
                                    url.contains(".flv") ||
                                    url.contains(".ts") ||
                                    url.contains("/video/") ||
                                    url.contains("/play/") ||
                                    url.contains("m3u8") ||
                                    url.contains("mp4")

                    if isVideoUrl && !url.isEmpty {
                        return url.trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }

        // 如果没有#分隔符，直接检查是否包含http
        if playUrl.contains("http") {
            if let urlRange = playUrl.range(of: "http") {
                var url = String(playUrl[urlRange.lowerBound...])

                // 清理尾部
                let stopChars = ["#", "\n", "\r", " "]
                for char in stopChars {
                    if let endRange = url.range(of: char) {
                        url = String(url[..<endRange.lowerBound])
                    }
                }

                // 验证
                let isVideoUrl = url.contains(".m3u8") ||
                                url.contains(".mp4") ||
                                url.contains(".flv") ||
                                url.contains("m3u8") ||
                                url.contains("mp4")

                if isVideoUrl && !url.isEmpty {
                    return url.trimmingCharacters(in: .whitespaces)
                }
            }
        }

        return nil
    }

    private func fetchDetail(url: URL, siteName: String) async -> VodItem? {
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

            print("[SpiderManager] fetchDetail 请求: \(url.absoluteString)")
            let (data, response) = try await URLSession.shared.data(for: req)

        if let httpResponse = response as? HTTPURLResponse {
            print("[SpiderManager] fetchDetail 响应状态: \(httpResponse.statusCode)")
            guard (200...299).contains(httpResponse.statusCode) else {
                print("[SpiderManager] fetchDetail 非200状态码: \(httpResponse.statusCode)")
                return nil
            }
        }

        if let rawStr = String(data: data, encoding: .utf8) {
            let preview = String(rawStr.prefix(500))
            print("[SpiderManager] fetchDetail 原始响应(前500): \(preview)")
        }

        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = json["list"] as? [[String: Any]],
           let first = list.first {
            // 打印完整字段名以便调试
            print("[SpiderManager] nativeDetail(ids) \(siteName) 第一条keys: \(first.keys.sorted())")

            // 打印关键字段的内容，用于调试
            print("[SpiderManager] === 关键字段内容 ===")
            for key in ["vod_id", "id", "vod_name", "name", "vod_pic", "pic", "vod_play_url", "play_url", "url", "vod_play_from", "play_from", "from"] {
                if first[key] != nil {
                    let value = first[key] ?? "nil"
                    if let stringValue = value as? String {
                        print("[SpiderManager] \(key): '\(stringValue.prefix(50))...'")
                    } else {
                        print("[SpiderManager] \(key): \(value)")
                    }
                }
            }
            print("[SpiderManager] === 字段内容结束 ===")

            let item = Self.makeVodItem(from: first, siteName: siteName)
            print("[SpiderManager] nativeDetail(ids) \(siteName): 解析结果:")
            print("[SpiderManager]   vodId: '\(item.vodId.prefix(20))...'")
            print("[SpiderManager]   vodName: '\(item.vodName)'")
            print("[SpiderManager]   vodPlayUrl: '\(item.vodPlayUrl?.prefix(50) ?? "nil")...'")
            print("[SpiderManager]   vodPlayFrom: '\(item.vodPlayFrom?.prefix(30) ?? "nil")...'")

            // 检查是否有播放地址
            if let playUrl = item.vodPlayUrl, !playUrl.isEmpty {
                print("[SpiderManager] ✅ nativeDetail 找到播放地址")
            } else if let playFrom = item.vodPlayFrom, !playFrom.isEmpty,
                      let playUrlRaw = item.vodPlayUrl {
                print("[SpiderManager] ✅ nativeDetail 找到 playFrom+playUrl 组合")
            } else {
                print("[SpiderManager] ⚠️ nativeDetail 无播放地址")
            }

            return item
        } else {
            print("[SpiderManager] fetchDetail JSON解析失败或list为空")
            // 尝试打印原始响应用于调试
            if let rawStr = String(data: data, encoding: .utf8) {
                print("[SpiderManager] 原始响应(前200字符): \(rawStr.prefix(200))")
            }
        }
    } catch {
        print("[SpiderManager] fetchDetail(ids) \(siteName) 失败: \(error.localizedDescription)")
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
        // 兼容多种字段名变体，包括各种拼写错误
        let vodId = String(describing: dict["vod_id"] ?? dict["id"] ?? dict["v_id"] ?? "")
        let vodName = (dict["vod_name"] as? String) ?? (dict["name"] as? String) ?? (dict["title"] as? String) ?? ""
        let vodPic = (dict["vod_pic"] as? String) ?? (dict["pic"] as? String) ?? (dict["img"] as? String) ?? ""
        let vodRemarks = siteName
        let vodYear = dict["vod_year"] as? String
        let vodDirector = dict["vod_director"] as? String
        let vodActor = dict["vod_actor"] as? String
        let vodContent = dict["vod_content"] as? String

        // 处理 vodPlayFrom - 兼容多种字段名
        var vodPlayFrom: String?
        let playFromKeys = ["vod_play_from", "play_from", "from", "vodFrom", "play_from_name", "vod_play_from_name"]
        for key in playFromKeys {
            if let from = dict[key] as? String, !from.isEmpty {
                vodPlayFrom = from
                break
            }
        }

        // 处理 vodPlayUrl - 兼容多种字段名，包括各种拼写错误
        var vodPlayUrl: String?
        let playUrlKeys = [
            "vod_play_url", "play_url", "url",
            "vodPlayUrl", "vodPrayUrt", "vodPlay Jri",  // 已知的拼写错误
            "vod_play_ur1", "vod_play_urt", "playurl",  // 其他可能的拼写错误
            "vod_play_urls", "urls", "play_urls", "video_url", "playUrl"
        ]

        for key in playUrlKeys {
            if let url = dict[key] as? String, !url.isEmpty {
                print("[SpiderManager] ✅ 使用字段名 '\(key)' 获取播放地址")
                vodPlayUrl = url
                break
            }
        }

        // 如果仍然没有找到播放地址，尝试模糊匹配
        if vodPlayUrl == nil {
            print("[SpiderManager] ⚠️ 标准字段名未找到播放地址，尝试模糊匹配...")
            for (key, value) in dict {
                if let stringValue = value as? String, !stringValue.isEmpty {
                    // 检查字段名是否包含 url 相关的关键词
                    let lowerKey = key.lowercased()
                    if lowerKey.contains("url") || lowerKey.contains("play") || lowerKey.contains("link") || lowerKey.contains("video") {
                        // 检查值是否看起来像是播放地址（包含 http 或 m3u8/mp4 关键字）
                        if stringValue.hasPrefix("http") || stringValue.contains("m3u8") || stringValue.contains("mp4") {
                            print("[SpiderManager] ✅ 模糊匹配找到字段 '\(key)': \(stringValue.prefix(50))...")
                            vodPlayUrl = stringValue
                            break
                        }
                    }
                } else if let arrayValue = value as? [String] {
                    // 处理数组类型的播放地址
                    if !arrayValue.isEmpty {
                        let firstUrl = arrayValue[0]
                        if firstUrl.hasPrefix("http") || firstUrl.contains("m3u8") || firstUrl.contains("mp4") {
                            print("[SpiderManager] ✅ 数组字段找到播放地址 '\(key)': \(firstUrl.prefix(50))...")
                            vodPlayUrl = firstUrl
                            break
                        }
                    }
                } else if let dictValue = value as? [String: Any] {
                    // 处理嵌套字典类型的播放地址
                    for (subKey, subValue) in dictValue {
                        if let subStringValue = subValue as? String {
                            let lowerSubKey = subKey.lowercased()
                            if (lowerSubKey.contains("url") || lowerSubKey.contains("play")) &&
                               (subStringValue.hasPrefix("http") || subStringValue.contains("m3u8") || subStringValue.contains("mp4")) {
                                print("[SpiderManager] ✅ 嵌套字段找到播放地址 '\(key).\(subKey)': \(subStringValue.prefix(50))...")
                                vodPlayUrl = subStringValue
                                break
                            }
                        }
                    }
                    if vodPlayUrl != nil {
                        break
                    }
                }
            }
        }

        // 特殊处理：如果 vodPlayFrom 存在但 vodPlayUrl 为空，尝试从所有字段中找到可能是播放地址的内容
        if vodPlayUrl == nil && vodPlayFrom != nil {
            print("[SpiderManager] ⚠️ vodPlayFrom 存在但 vodPlayUrl 为空，尝试从所有字段中提取...")
            for (key, value) in dict {
                if let stringValue = value as? String, !stringValue.isEmpty {
                    // 跳过已经检查过的字段
                    if key == "vod_id" || key == "id" || key == "vod_name" || key == "name" || key == "title" {
                        continue
                    }
                    // 检查是否包含视频特征
                    if stringValue.contains("://") || stringValue.contains(".m3u8") || stringValue.contains(".mp4") || stringValue.contains("#") {
                        print("[SpiderManager] ✅ 从字段 '\(key)' 提取可能的播放地址：\(stringValue.prefix(80))...")
                        vodPlayUrl = stringValue
                        break
                    }
                }
            }
        }

        // 如果仍然没有找到，打印所有可用字段名用于调试
        if vodPlayUrl == nil {
            print("[SpiderManager] ❌ 未找到播放地址字段")
            print("[SpiderManager] 可用字段名：\(dict.keys.sorted())")
            print("[SpiderManager] 所有字段值（前 100 字符）:")
            for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                if let stringValue = value as? String {
                    let displayValue = stringValue.count > 100 ? String(stringValue.prefix(100)) + "..." : stringValue
                    print("[SpiderManager]   \(key): '\(displayValue)'")
                } else {
                    print("[SpiderManager]   \(key): \(type(of: value)) = \(value)")
                }
            }
        }

        return VodItem(
            vodId: vodId,
            vodName: vodName,
            vodPic: vodPic,
            vodRemarks: vodRemarks,
            vodYear: vodYear,
            vodDirector: vodDirector,
            vodActor: vodActor,
            vodContent: vodContent,
            vodPlayFrom: vodPlayFrom,
            vodPlayUrl: vodPlayUrl
        )
    }
}

