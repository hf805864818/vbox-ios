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
    var enginesCount: Int { engines.count }
    
    private let subManager = SubscriptionManager()
    private var engines: [String: QJSSpiderEngine] = [:]
    
    private init() {
        savedURLs = subManager.configURLs
    }
    
    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true
        if subManager.isLoaded {
            await loadSitesFromSubscription()
        }
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
        
        // 2. 使用内置蜘蛛
        if !spiderLoaded {
            print("[SpiderManager] 使用内置蜘蛛引擎")
            let builtinSite = SiteConfig(key: "builtin", name: "内置搜索", type: 3, api: "builtin", ext: nil)
            self.allSites.insert(builtinSite, at: 0)
            loadedSiteCount = allSites.count
            do {
                try await loadSpiderEngine(jsCode: getBuiltinSpiderJS())
                spiderLoaded = true
                print("[SpiderManager] ✅ 内置蜘蛛加载成功")
            } catch {
                print("[SpiderManager] ❌ 内置蜘蛛加载失败: \(error.localizedDescription)")
                errorMessage = "蜘蛛加载失败"
            }
        }
        
        // 3. 尝试加载每个站点的 ext 字段（如果是 JS 的话）
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
        engine.onLog = { msg in print("[SpiderEngine] \(msg)") }
        try engine.loadScript(jsCode)
        if engine.registerSpider() {
            engines["builtin"] = engine
            if !subscribedSites.contains("builtin") {
                subscribedSites.append("builtin")
            }
        } else {
            throw QJSError(message: "蜘蛛注册失败")
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
        var all: [VodItem] = []
        for (_, engine) in engines {
            do {
                if let items = try engine.callSearchContent(keyword: keyword, pg: pg).list {
                    all.append(contentsOf: items)
                }
            } catch { continue }
        }
        return all
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
    
    /// 内置蜘蛛 JS 代码
    private func getBuiltinSpiderJS() -> String {
        return """
let BUILTIN_SPIDER = (function() {
    const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
    const API_SOURCES = [
        { name: "资源1", url: "https://json.im30.app/vod/" },
        { name: "资源2", url: "https://api.apibdzy.com/api.php/provide/vod/from/jsonim/" },
    ];
    const HOME_CATEGORIES = [
        { type_id: 1, type_name: "电影" },
        { type_id: 2, type_name: "电视剧" },
        { type_id: 3, type_name: "综艺" },
        { type_id: 4, type_name: "动漫" },
    ];
    function httpReq(url) {
        try { let resp = http(url, { headers: { "User-Agent": UA }, timeout: 10 }); if (resp && resp.ok && resp.content) return resp.content; } catch(e) {}
        return null;
    }
    function fetchJSON(url) { let h = httpReq(url); if (!h) return null; try { return JSON.parse(h); } catch(e) { return null; } }
    function fmt(item) {
        return { vod_id: String(item.vod_id || item.id || ""), vod_name: item.vod_name || item.name || "", vod_pic: item.vod_pic || item.pic || "", vod_remarks: item.vod_remarks || "", vod_year: item.vod_year || "", vod_actor: item.vod_actor || "", vod_director: item.vod_director || "" };
    }
    function homeContent() {
        let classes = HOME_CATEGORIES.map(function(c) { return { type_id: String(c.type_id), type_name: c.type_name }; });
        let data = fetchJSON(API_SOURCES[0].url + "?ac=list&t=1&pg=1&pagesize=20");
        let list = (data && data.list) ? data.list.map(fmt) : [];
        return { class: classes, list: list };
    }
    function searchContent(keyword, pg) {
        pg = pg || 1; let all = [];
        for (let i = 0; i < API_SOURCES.length; i++) {
            let data = fetchJSON(API_SOURCES[i].url + "?ac=videolist&wd=" + encodeURIComponent(keyword) + "&pg=" + pg);
            if (data && data.list) all = all.concat(data.list.map(fmt));
        }
        let seen = {}; let unique = [];
        for (let i = 0; i < all.length; i++) { let k = all[i].vod_id + "|" + all[i].vod_name; if (!seen[k]) { seen[k] = true; unique.push(all[i]); } }
        return { list: unique };
    }
    function detailContent(ids) {
        let id = ids.split(",")[0];
        for (let i = 0; i < API_SOURCES.length; i++) {
            let data = fetchJSON(API_SOURCES[i].url + "?ac=detail&ids=" + id);
            if (data && data.list && data.list.length > 0) {
                let item = data.list[0];
                return { list: [{ vod_id: id, vod_name: item.vod_name || "", vod_pic: item.vod_pic || "", vod_actor: item.vod_actor || "", vod_director: item.vod_director || "", vod_content: item.vod_content || "", vod_year: item.vod_year || "", vod_remarks: item.vod_remarks || "", vod_play_from: item.vod_play_from || "资源站", vod_play_url: item.vod_play_url || "" }] };
            }
        }
        return { list: [] };
    }
    function playerContent(vod_id, flag, url) {
        if (url && (url.startsWith("http://") || url.startsWith("https://"))) {
            return { parse: 0, playUrl: "", url: url, header: { "User-Agent": UA, "Referer": "https://www.baidu.com/" } };
        }
        return { parse: 1, playUrl: "https://json.im30.app/parse.php?url=" + encodeURIComponent(url), url: url, header: {} };
    }
    return { init: function() {}, homeContent: homeContent, searchContent: searchContent, detailContent: detailContent, playerContent: playerContent };
})();
if (typeof globalThis.__JS_SPIDER__ === 'undefined') { globalThis.__JS_SPIDER__ = BUILTIN_SPIDER; globalThis.__JS_SPIDER__.is_cat = true; }
"""
    }
}
