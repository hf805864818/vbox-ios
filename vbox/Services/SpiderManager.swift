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
    
    /// 获取内置蜘蛛 JS 代码 — 乌云影视直连搜索（同步版）
    private func getBuiltinSpiderJS() -> String {
        return """
// 基础辅助类
function VideoDetail() { this.vod_id = ""; this.vod_name = ""; this.vod_pic = ""; this.vod_remarks = ""; }
function RepVideoList() { this.data = []; this.total = 0; this.error = ""; }
function RepVideoClassList() { this.data = []; this.error = ""; }

// req 包装 — http() 是同步的，直接用
function req(url, options) {
    var opts = options || {};
    var jsonResult = http(url, JSON.stringify({
        method: opts.method || 'GET',
        headers: opts.headers || {},
        data: opts.data || '',
        timeout: 15
    }));
    var resp = JSON.parse(jsonResult);
    resp.data = resp.content;
    return resp;
}

// 乌云影视搜索蜘蛛 — 全部同步
var wooyun = {
    webSite: 'https://wooyun.tv',
    getHeaders: function() {
        return {
            Referer: this.webSite,
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
        };
    },
    search: function(keyword, page) {
        var back = new RepVideoList();
        if (!keyword) { back.data = []; return JSON.stringify(back); }
        try {
            var url = this.webSite + '/api/proxy?url=%2Fmovie%2Fmedia%2Fsearch';
            var body = JSON.stringify({
                menuCodeList: [],
                pageIndex: String(page || 1),
                pageSize: 10,
                searchKey: keyword,
                topCode: ''
            });
            var resp = req(url, { method: 'POST', headers: this.getHeaders(), data: body });
            if (!resp.ok) { back.error = 'HTTP ' + resp.status; return JSON.stringify(back); }
            var json = JSON.parse(resp.data || '{}');
            var records = (json.data && json.data.records) ? json.data.records : [];
            back.total = (json.data && json.data.total) ? json.data.total : 0;
            for (var i = 0; i < records.length; i++) {
                var item = records[i];
                var v = new VideoDetail();
                v.vod_id = String(item.id || '');
                v.vod_name = item.title || '';
                v.vod_pic = item.posterUrlS3 || item.posterUrl || '';
                v.vod_remarks = '乌云影视';
                back.data.push(v);
            }
        } catch(e) { back.error = String(e); }
        return JSON.stringify(back);
    },
    home: function() {
        var web = this.webSite;
        try {
            var url = web + '/api/proxy?url=%2Fmovie%2Fmedia%2Fsearch';
            var body = JSON.stringify({ menuCodeList: [], pageIndex: '1', pageSize: 10, searchKey: '', sortCode: 'newest', topCode: 'movie' });
            var resp = req(url, { method: 'POST', headers: this.getHeaders(), data: body });
            var json = JSON.parse(resp.data || '{}');
            var records = (json.data && json.data.records) ? json.data.records : [];
            var list = [];
            for (var i = 0; i < records.length; i++) {
                var item = records[i];
                var v = new VideoDetail();
                v.vod_id = String(item.id || '');
                v.vod_name = item.title || '';
                v.vod_pic = item.posterUrlS3 || item.posterUrl || '';
                v.vod_remarks = '乌云影视';
                list.push(v);
            }
            return JSON.stringify({
                class: [
                    { type_id: '1', type_name: '电影' },
                    { type_id: '2', type_name: '电视剧' },
                    { type_id: '3', type_name: '综艺' },
                    { type_id: '4', type_name: '动漫' }
                ],
                list: list
            });
        } catch(e) {
            return JSON.stringify({ class: [], list: [] });
        }
    },
    detail: function(ids) {
        return JSON.stringify({ list: [] });
    },
    player: function(vodId, flag, url) {
        return JSON.stringify({ parse: 0, url: url });
    }
};

// 注册蜘蛛
var _spider = {
    homeContent: function() { return wooyun.home(); },
    searchContent: function(keyword, page) { return wooyun.search(keyword, page); },
    detailContent: function(ids) { return wooyun.detail(ids); },
    playerContent: function(vodId, flag, url) { return wooyun.player(vodId, flag, url); }
};
globalThis.__JS_SPIDER__ = _spider;
console.log('蜘蛛注册完成: 乌云影视 v1');
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
        
        // 1. 尝试从订阅源的 spider 字段加载 JS 蜘蛛
        var spiderLoaded = false
        if let spiderURL = config.spider, spiderURL.hasPrefix("http") {
            do {
                let rawData = try await downloadRawData(url: spiderURL)
                if let snippet = String(data: rawData, encoding: .utf8),
                   snippet.count > 100,
                   snippet.contains("function ") || snippet.contains("var ") || snippet.contains("let ") || snippet.contains("const ") {
                    try await loadSpiderEngine(jsCode: snippet)
                    spiderLoaded = true
                    print("[SpiderManager] ✅ 远程蜘蛛加载成功")
                } else {
                    print("[SpiderManager] spider URL 不是纯 JS（可能是 jar 包），使用内置蜘蛛")
                }
            } catch {
                print("[SpiderManager] spider URL 加载失败: \(error.localizedDescription)")
            }
        }
        
        // 2. 尝试加载每个站点的 ext 字段（如果是 JS 的话）
        for site in allSites where site.key != "builtin" {
            if let jsURL = site.ext, jsURL.hasPrefix("http"), !jsURL.isEmpty {
                do {
                    let rawData = try await downloadRawData(url: jsURL)
                    if let snippet = String(data: rawData, encoding: .utf8),
                       snippet.count > 200,
                       snippet.contains("function ") || snippet.contains("spider") {
                        try await loadSiteEngine(site: site, jsURL: jsURL)
                    }
                } catch { /* 静默跳过 */ }
            }
        }
        
        print("[SpiderManager] 蜘蛛引擎: \(spiderLoaded ? "✅" : "❌"), 引擎数: \(engines.count)")
        await loadHomeData()
    }
    
    /// 加载蜘蛛 JS 到引擎
    private func loadSpiderEngine(jsCode: String) async throws {
        let engine = QJSSpiderEngine()
        engine.onLog = { msg in
            print("[SpiderEngine] \(msg)")
            if msg.contains("❌") || msg.contains("异常") || msg.contains("失败") {
                Task { @MainActor in self.engineError = msg }
            }
        }
        try engine.loadScript(jsCode)
        if engine.registerSpider() {
            engines["builtin"] = engine
            if !subscribedSites.contains("builtin") {
                subscribedSites.append("builtin")
            }
            engineError = nil
        } else {
            let err = "蜘蛛注册失败: __JS_SPIDER__ 未找到"
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
        guard !engines.isEmpty else {
            print("[SpiderManager] 没有引擎，无法加载首页")
            return
        }
        if let (_, engine) = engines.first {
            do {
                let result = try engine.callHomeContent()
                self.categories = result.class ?? []
                self.homeVideos = result.list ?? []
                print("[SpiderManager] 首页: \(homeVideos.count)视频 \(categories.count)分类")
            } catch {
                print("[SpiderManager] 首页失败: \(error.localizedDescription)")
            }
        }
    }
    
    func search(keyword: String, pg: Int = 1) async -> [VodItem] {
        // 先尝试加载内置蜘蛛
        if engines.isEmpty {
            await loadBuiltinEngineIfNeeded()
        }
        
        // 如果 QuickJS 引擎加载成功，用 QuickJS 搜索
        for (_, engine) in engines {
            do {
                if let items = try engine.callSearchContent(keyword: keyword, pg: pg).list {
                    return items
                }
            } catch {
                engineError = "搜索出错: \(error.localizedDescription)"
                print("[SpiderManager] QuickJS 搜索失败: \(error)")
            }
        }
        
        // QuickJS 失败或未加载，走纯 Swift 搜索
        return await nativeSearch(keyword: keyword)
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
    
    /// 纯 Swift 搜索 — 从订阅源中找 type=1 的站点 API 进行搜索
    func nativeSearch(keyword: String) async -> [VodItem] {
        var allResults: [VodItem] = []
        var seenIds = Set<String>()
        
        // 从订阅源收集 type=1（API 直连）的站点
        let apiSites = allSites.filter { $0.type == 1 && $0.api != nil && !$0.api!.isEmpty }
        
        // 如果没有 type=1 站点，使用硬编码的备用搜索 API
        let searchURLs: [(name: String, url: String)] = apiSites.isEmpty ? [
            ("非凡资源", "http://ffzy1.tv/api.php/provide/vod/?ac=detail&wd={wd}"),
            ("虎牙采集", "https://www.huyaapi.com/api.php/provide/vod/from/hym3u8?ac=detail&wd={wd}"),
            ("火狐采集", "https://hhzyapi.com/api.php/provide/vod/?ac=detail&wd={wd}"),
            ("百度采集", "https://api.apibdzy.com/api.php/provide/vod/?ac=detail&wd={wd}"),
        ] : []
        
        // 并发搜索
        let encodedKW = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        
        // 从 API 站点搜索
        for site in apiSites {
            guard let api = site.api, !api.isEmpty else { continue }
            // 替换变量
            var urlStr = api.replacingOccurrences(of: "{wd}", with: encodedKW)
                .replacingOccurrences(of: "{keyword}", with: encodedKW)
            // 把 ac=list 改成 ac=detail 搜索模式
            urlStr = urlStr.replacingOccurrences(of: "ac=list", with: "ac=detail")
            // 追加搜索关键词参数
            if urlStr.contains("?wd=") || urlStr.contains("&wd=") {
                // 已经有了 wd 参数，跳过
            } else if urlStr.contains("?") {
                urlStr = urlStr + "&ac=detail&wd=" + encodedKW
            } else {
                urlStr = urlStr + "?ac=detail&wd=" + encodedKW
            }
            // 避免双 ? 双 ac=detail
            let finalURL = urlStr
                .replacingOccurrences(of: "?ac=detail&ac=detail", with: "?ac=detail")
                .replacingOccurrences(of: "&ac=detail&ac=detail", with: "&ac=detail")
            
            print("[SpiderManager] 请求: \(finalURL.prefix(80))")
            
            if let results = await searchWithAPI(url: finalURL, sourceName: site.name) {
                for item in results {
                    let id = item.vodId.isEmpty ? item.vodName : item.vodId
                    if !seenIds.contains(id), seenIds.count < 50 {
                        seenIds.insert(id)
                        allResults.append(item)
                    }
                }
            }
        }
        
        // 备用硬编码 API
        for (name, urlTemplate) in searchURLs {
            let urlStr = urlTemplate.replacingOccurrences(of: "{wd}", with: encodedKW)
            if let results = await searchWithAPI(url: urlStr, sourceName: name) {
                for item in results {
                    let id = item.vodId.isEmpty ? item.vodName : item.vodId
                    if !seenIds.contains(id), seenIds.count < 50 {
                        seenIds.insert(id)
                        allResults.append(item)
                    }
                }
            }
        }
        
        print("[SpiderManager] nativeSearch 获得 \(allResults.count) 个结果")
        return allResults
    }
    
    /// 通用 JSON 搜索接口调用
    private func searchWithAPI(url: String, fieldMap: [String: String] = [:], sourceName: String = "") async -> [VodItem]? {
        guard let urlObj = URL(string: url) else { return nil }
        var req = URLRequest(url: urlObj)
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            
            // 尝试多种 JSON 结构
            var list: [[String: Any]]? = nil
            
            // 结构1: { "list": [...] }
            if let l = json["list"] as? [[String: Any]] { list = l }
            // 结构2: { "data": { "list": [...] } }
            else if let dataObj = json["data"] as? [String: Any], let l = dataObj["list"] as? [[String: Any]] { list = l }
            // 结构3: { "videos": [...] }
            else if let l = json["videos"] as? [[String: Any]] { list = l }
            // 结构4: { "data": [...] }
            else if let l = json["data"] as? [[String: Any]] { list = l }
            // 结构5: { "results": [...] }
            else if let l = json["results"] as? [[String: Any]] { list = l }
            // 结构6: [ ... ] (直接数组)
            else if let l = json as? [[String: Any]] { return l.map { mapVodItem($0, fieldMap: fieldMap, sourceName: sourceName) } }
            
            guard let items = list else { return nil }
            return items.map { mapVodItem($0, fieldMap: fieldMap, sourceName: sourceName) }
        } catch {
            return nil
        }
    }
    
    private func mapVodItem(_ item: [String: Any], fieldMap: [String: String], sourceName: String = "") -> VodItem {
        let idField = fieldMap["vod_id"] ?? "vod_id"
        let nameField = fieldMap["vod_name"] ?? "vod_name"
        let picField = fieldMap["vod_pic"] ?? "vod_pic"
        return VodItem(
            vodId: String(describing: item[idField] ?? item["id"] ?? ""),
            vodName: (item[nameField] as? String) ?? (item["title"] as? String) ?? (item["name"] as? String) ?? "",
            vodPic: (item[picField] as? String) ?? (item["cover"] as? String) ?? (item["image"] as? String) ?? (item["pic"] as? String) ?? "",
            vodRemarks: !sourceName.isEmpty ? sourceName : (item["vod_remarks"] as? String),
            vodYear: item["vod_year"] as? String ?? item["year"] as? String,
            vodArea: item["vod_area"] as? String ?? item["area"] as? String,
            vodDirector: item["vod_director"] as? String ?? item["director"] as? String,
            vodActor: item["vod_actor"] as? String ?? item["actor"] as? String
        )
    }
}
