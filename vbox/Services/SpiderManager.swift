import Foundation
import SwiftUI

/// 站点模式枚举 — 用于区分站点的实际工作模式
enum SiteMode {
    case jsSpider       // JS蜘蛛模式：加载JS脚本到引擎
    case apiEndpoint    // API模式：直接HTTP调用CMS接口
    case zhanyuan       // 站源模式：HTML解析
    case unsupported    // 不支持的类型（jar包等）
}

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
    @Published var customParsers: [ParseConfig] = []  // 用户自定义解析器
    @Published var fallbackEnabled: Bool = true {   // 兜底源开关
        didSet { UserDefaults.standard.set(fallbackEnabled, forKey: "fallback_enabled") }
    }
    @Published var customFallbackSites: [(name: String, api: String)] = []  // 自定义兜底源
    var enginesCount: Int { engines.count }

    // 内置兜底采集 API 站
    static let builtinFallbackSites: [(name: String, api: String)] = [
        ("闪电资源",   "https://sdzyapi.com/api.php/provide/vod"),
        ("光速资源",   "https://api.guangsuapi.com/api.php/provide/vod"),
        ("新浪资源",   "https://api.xinlangapi.com/xinlangapi.php/provide/vod"),
        ("量子资源",   "https://cj.lziapi.com/api.php/provide/vod"),
        ("暴风资源",   "https://bfzyapi.com/api.php/provide/vod"),

        ("红牛资源",   "https://www.hongniuzy2.com/api.php/provide/vod"),

        ("4KTOP蓝光",  "https://4ktop.com/api.php/provide/vod"),
        ("盘Ta资源",   "https://www.91panta.cn/api.php/provide/vod"),
        ("多多资源",   "https://tv.yydsys.top/api.php/provide/vod"),
        ("至臻影视",   "http://www.miqk.cc/api.php/provide/vod"),
        ("LibVio影视", "https://libvio.mov/api.php/provide/vod"),
    ]

    let subManager = SubscriptionManager()
    /// 主引擎字典 — 统一使用协议类型，支持 JSC 和 QuickJS
    private var engines: [String: SpiderEngineProtocol] = [:]
    /// 记录每个引擎使用的类型（用于诊断显示）
    private var engineTypes: [String: SpiderEngineType] = [:]
    private var cloudPlayCache: [String: (links: [(url: String, name: String)], siteName: String, expiresAt: Date)] = [:]
    
    /// 获取指定 key 的引擎类型
    func engineType(forKey key: String) -> SpiderEngineType? {
        return engineTypes[key]
    }
    
    /// 获取所有引擎的统计信息（用于诊断）
    var engineTypeStats: [(key: String, type: SpiderEngineType)] {
        return engineTypes.map { ($0.key, $0.value) }
    }
    
    /// 检查是否有指定 key 的引擎
    func hasEngine(forKey key: String) -> Bool {
        return engines[key] != nil
    }
    
    /// 获取引擎加载统计
    var engineStats: (loaded: Int, total: Int) {
        return (engines.count, allSites.count)
    }

    private init() {
        self.fallbackEnabled = UserDefaults.standard.object(forKey: "fallback_enabled") as? Bool ?? true
        savedURLs = subManager.configURLs
        loadCustomParsers()
        loadCustomFallbackSites()
    }

    // MARK: - 双模式功能开关
    /// 是否启用双模式支持（type=3 HTTP API 站点走原生HTTP链路）
    /// 关闭时完全回到改造前的行为，100%兼容
    var enableDualMode: Bool {
        get { UserDefaults.standard.object(forKey: "enable_dual_mode") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "enable_dual_mode") }
    }

    // MARK: - 站点模式识别（双模式支持）
    /// 根据站点配置判断其实际工作模式
    /// 核心逻辑：type=3 不一定是JS蜘蛛，需根据 api 字段特征判断
    func resolveSiteMode(site: SiteConfig) -> SiteMode {
        guard let api = site.api, !api.isEmpty else {
            return .unsupported
        }

        // 开关关闭时，type=3 全部按原有逻辑处理（尝试加载JS）
        if !enableDualMode && site.type == 3 {
            // 原有逻辑：非http且非.js的视为jar类名，不支持
            if !api.hasPrefix("http://") && !api.hasPrefix("https://") && !api.hasPrefix("./") && !api.hasSuffix(".js") {
                return .unsupported
            }
            if api.lowercased().contains(".jar") {
                return .unsupported
            }
            return .jsSpider
        }

        switch site.type {
        case 0, 1:
            return .apiEndpoint
        case 2:
            return .zhanyuan
        case 3:
            // jar 包不支持
            if api.lowercased().contains(".jar") {
                return .unsupported
            }
            // HTTP/HTTPS URL：进一步判断是JS文件还是API接口
            if api.hasPrefix("http://") || api.hasPrefix("https://") {
                // 以 .js 结尾的 HTTP URL → JS蜘蛛模式
                if api.lowercased().hasSuffix(".js") {
                    return .jsSpider
                }
                // 不以 .js 结尾的 HTTP URL → 视为CMS API接口
                return .apiEndpoint
            }
            // 相对路径 ./xxx.js 或纯JS文件名 → JS蜘蛛模式
            if api.hasSuffix(".js") || api.hasPrefix("./") {
                return .jsSpider
            }
            // 纯类名如 csp_Douban → jar包，不支持
            return .unsupported
        default:
            return .unsupported
        }
    }

    // MARK: - 兜底源管理
    func saveCustomFallbackSites() {
        let arr = customFallbackSites.map { ["name": $0.name, "api": $0.api] }
        UserDefaults.standard.set(arr, forKey: "custom_fallback_sites")
    }

    private func loadCustomFallbackSites() {
        guard let arr = UserDefaults.standard.array(forKey: "custom_fallback_sites") as? [[String: String]] else { return }
        customFallbackSites = arr.compactMap { dict in
            guard let name = dict["name"], let api = dict["api"] else { return nil }
            return (name, api)
        }
    }

    func addCustomFallbackSite(name: String, api: String) {
        guard !customFallbackSites.contains(where: { $0.api == api }) else { return }
        customFallbackSites.append((name, api))
        saveCustomFallbackSites()
    }

    func removeCustomFallbackSite(at index: Int) {
        guard index >= 0, index < customFallbackSites.count else { return }
        customFallbackSites.remove(at: index)
        saveCustomFallbackSites()
    }

    /// 所有兜底源 = 内置 + 自定义
    var allFallbackSites: [(name: String, api: String)] {
        var sites = Self.builtinFallbackSites
        for cs in customFallbackSites {
            if !sites.contains(where: { $0.api == cs.api }) {
                sites.append(cs)
            }
        }
        return sites
    }

    /// 加载自定义解析器（内置 + 用户自定义）
    private func loadCustomParsers() {
        // 内置解析器已全部失效（2025-06-18检测），仅保留用户自定义解析器
        // 用户可通过设置页添加有效的第三方解析器
        customParsers = []
        if let data = UserDefaults.standard.data(forKey: "custom_parsers"),
           let parsers = try? JSONDecoder().decode([ParseConfig].self, from: data) {
            customParsers = parsers
        }
    }

    /// 保存自定义解析器
    func saveCustomParsers() {
        if let data = try? JSONEncoder().encode(customParsers) {
            UserDefaults.standard.set(data, forKey: "custom_parsers")
        }
    }

    /// 添加自定义解析器
    func addCustomParser(name: String, url: String) {
        let parser = ParseConfig(name: name, url: url, type: nil)
        if !customParsers.contains(where: { $0.url == url }) {
            customParsers.append(parser)
            saveCustomParsers()
        }
    }

    /// 删除自定义解析器
    func removeCustomParser(at index: Int) {
        guard index >= 0, index < customParsers.count else { return }
        customParsers.remove(at: index)
        saveCustomParsers()
    }

    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true

        // 尝试加载 QuickJS 内置蜘蛛
        await loadBuiltinEngineIfNeeded()

        // 加载激活的订阅源
        if let activeURL = subManager.activeURL {
            print("[SpiderManager] 加载激活的订阅源: \(activeURL)")
            await subManager.loadConfig(from: activeURL)
        }

        // 无论是否有订阅源，都加载站点配置（内置站点作为兜底）
        await loadSitesFromSubscription()

        print("[SpiderManager] 初始化完成，引擎数: \(engines.count), 站点数: \(allSites.count)")
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

    /// 加载指定 URL 的订阅源（添加新订阅时用）
    func loadSubscribeConfig(from url: String) async {
        isLoading = true
        errorMessage = nil
        await subManager.loadConfig(from: url)
        if let error = subManager.errorMessage {
            errorMessage = error
            isLoading = false
            return
        }
        // 新加载的设为激活
        if let idx = subManager.configURLs.firstIndex(of: url) {
            subManager.switchToSubscription(at: idx)
        }
        await loadSitesFromSubscription()
        savedURLs = subManager.configURLs
        isLoading = false
    }

    /// 加载当前激活的订阅源
    func loadActiveSubscription() async {
        guard let activeURL = subManager.activeURL else {
            print("[SpiderManager] 没有激活的订阅源")
            return
        }
        isLoading = true
        errorMessage = nil
        await subManager.loadConfig(from: activeURL)
        if let error = subManager.errorMessage {
            errorMessage = error
            isLoading = false
            return
        }
        await loadSitesFromSubscription()
        savedURLs = subManager.configURLs
        isLoading = false
    }

    /// 切换激活的订阅源
    func switchToSubscription(at index: Int) {
        subManager.switchToSubscription(at: index)
        engines.removeAll()
        subscribedSites.removeAll()
        allSites = []
        loadedSiteCount = 0
        Task { await loadActiveSubscription() }
    }

    private func loadSitesFromSubscription() async {
        // 先加载内置 ibox_sources.json（无论用户是否添加了订阅源）
        // 多路径查找策略，确保文件被正确找到
        var iboxSites: [SiteConfig] = []
        var iboxLoaded = false

        // 方式1: 标准 path（带 inDirectory）
        if let iboxPath = Bundle.main.path(forResource: "ibox_sources", ofType: "json", inDirectory: "js"),
           let iboxData = try? Data(contentsOf: URL(fileURLWithPath: iboxPath)) {
            do {
                let iboxConfig = try JSONDecoder().decode(SubscribeConfig.self, from: iboxData)
                iboxSites = iboxConfig.sites
                iboxLoaded = true
                print("[SpiderManager] 从 ibox_sources.json(js/) 读取了 \(iboxSites.count) 个站点")
            } catch {
                print("[SpiderManager] ibox_sources.json 解析失败: \(error.localizedDescription)")
            }
        }
        // 方式2: 不带 inDirectory（文件夹引用可能扁平化）
        if !iboxLoaded, let iboxPath = Bundle.main.path(forResource: "ibox_sources", ofType: "json"),
           let iboxData = try? Data(contentsOf: URL(fileURLWithPath: iboxPath)) {
            do {
                let iboxConfig = try JSONDecoder().decode(SubscribeConfig.self, from: iboxData)
                iboxSites = iboxConfig.sites
                iboxLoaded = true
                print("[SpiderManager] 从 Bundle 根目录读取 ibox_sources.json: \(iboxSites.count) 个站点")
            } catch {
                print("[SpiderManager] ibox_sources.json 解析失败: \(error.localizedDescription)")
            }
        }
        // 方式3: url(forResource:withExtension:subdirectory:)
        if !iboxLoaded, let iboxURL = Bundle.main.url(forResource: "ibox_sources", withExtension: "json", subdirectory: "js"),
           let iboxData = try? Data(contentsOf: iboxURL) {
            do {
                let iboxConfig = try JSONDecoder().decode(SubscribeConfig.self, from: iboxData)
                iboxSites = iboxConfig.sites
                iboxLoaded = true
                print("[SpiderManager] 从 url(subdirectory:js) 读取 ibox_sources.json: \(iboxSites.count) 个站点")
            } catch {
                print("[SpiderManager] ibox_sources.json 解析失败: \(error.localizedDescription)")
            }
        }
        // 方式4: 枚举 Bundle.resources 查找
        if !iboxLoaded {
            if let jsURLs = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "js"),
               let iboxFile = jsURLs.first(where: { $0.lastPathComponent == "ibox_sources.json" }),
               let iboxData = try? Data(contentsOf: iboxFile) {
                do {
                    let iboxConfig = try JSONDecoder().decode(SubscribeConfig.self, from: iboxData)
                    iboxSites = iboxConfig.sites
                    iboxLoaded = true
                    print("[SpiderManager] 从 urls(js/) 枚举找到 ibox_sources.json: \(iboxSites.count) 个站点")
                } catch {
                    print("[SpiderManager] ibox_sources.json 解析失败: \(error.localizedDescription)")
                }
            }
            // 也检查 Bundle 根目录的 json 文件
            if !iboxLoaded, let allJSONs = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil),
               let iboxFile = allJSONs.first(where: { $0.lastPathComponent == "ibox_sources.json" }),
               let iboxData = try? Data(contentsOf: iboxFile) {
                do {
                    let iboxConfig = try JSONDecoder().decode(SubscribeConfig.self, from: iboxData)
                    iboxSites = iboxConfig.sites
                    iboxLoaded = true
                    print("[SpiderManager] 从 urls(根目录) 枚举找到 ibox_sources.json: \(iboxSites.count) 个站点")
                } catch {
                    print("[SpiderManager] ibox_sources.json 解析失败: \(error.localizedDescription)")
                }
            }
        }
        if !iboxLoaded {
            print("[SpiderManager] ⚠️ 未找到 ibox_sources.json（已尝试4种查找方式）")
        }

        // 如果 subManager.config 为空但之前通过 apiyuan 转换过站点，
        // 从 subManager 的内部加载
        guard let config = subManager.config else {
            // config 为 nil 说明没有订阅源，直接使用内置 ibox 站点
            if !iboxSites.isEmpty {
                self.allSites = iboxSites
                loadedSiteCount = allSites.count
                print("[SpiderManager] 无订阅源，使用内置 ibox_sources: \(loadedSiteCount) 个站点")
            } else {
                self.allSites = []
                loadedSiteCount = 0
                errorMessage = "订阅源配置为空"
                // 无订阅源时清空数据库中的 zhanyuan/aphiyuan 残留数据
                DatabaseManager.shared.clearAllZhanyuanSites()
                DatabaseManager.shared.clearAllApiYuanSites()
                print("[SpiderManager] 无订阅源，已清空数据库站源残留")
                return
            }
            // 加载引擎
            await loadBuiltinEngineIfNeeded()
            let totalSites = allSites.count
            print("[SpiderManager] 可用蜘蛛引擎: \(engines.count)个")
            print("[SpiderManager] 可用API站点: \(allSites.filter { $0.api?.hasPrefix("http") ?? false }.count)个")
            return
        }

        self.allSites = config.sites
        loadedSiteCount = allSites.count

        // 合并内置 ibox 站点（去重）
        if !iboxSites.isEmpty {
            let existingKeys = Set(allSites.map { $0.key })
            let newSites = iboxSites.filter { !existingKeys.contains($0.key) }
            if !newSites.isEmpty {
                self.allSites.append(contentsOf: newSites)
                loadedSiteCount = allSites.count
                print("[SpiderManager] 从 ibox_sources.json 合并了 \(newSites.count) 个站点，总计: \(loadedSiteCount)")
            }
        }

        // 0. 先确保内置蜘蛛加载
        await loadBuiltinEngineIfNeeded()

        // 1. 尝试从订阅源的 spider 字段加载全局 JS 蜘蛛
        if let spiderField = config.spider, !spiderField.isEmpty {
            // 提取实际 URL（spider 字段可能包含分号分隔的 md5 签名）
            let spiderURL: String
            if spiderField.contains(";") {
                spiderURL = spiderField.components(separatedBy: ";").first ?? spiderField
            } else {
                spiderURL = spiderField
            }

            // 检查是否是 jar 包
            if spiderURL.lowercased().contains(".jar") {
                print("[SpiderManager] spider 字段是 jar 包，iOS 不支持 Java 蜘蛛，跳过: \(spiderURL.prefix(80))")
            } else if spiderURL.hasPrefix("http://") || spiderURL.hasPrefix("https://") {
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
            } else if spiderURL.hasPrefix("./") {
                // 相对路径，拼接订阅源 baseURL
                let baseURL = subManager.activeURL ?? ""
                let fullURL: String
                if let url = URL(string: baseURL) {
                    fullURL = url.deletingLastPathComponent().appendingPathComponent(spiderURL).absoluteString
                } else {
                    fullURL = spiderURL
                }
                print("[SpiderManager] spider 相对路径拼接: \(spiderURL) -> \(fullURL)")
                do {
                    let rawData = try await downloadRawData(url: fullURL)
                    if let snippet = String(data: rawData, encoding: .utf8),
                       snippet.count > 100,
                       (snippet.contains("function ") || snippet.contains("var ") || snippet.contains("let ") || snippet.contains("const ")) {
                        try await loadSpiderEngine(jsCode: snippet, key: "remote_spider")
                        print("[SpiderManager] ✅ 远程蜘蛛(相对路径)加载成功")
                    } else {
                        print("[SpiderManager] spider 相对路径内容不是有效 JS，跳过")
                    }
                } catch {
                    print("[SpiderManager] spider 相对路径加载失败: \(error.localizedDescription)")
                }
            } else {
                print("[SpiderManager] spider 字段格式无法识别，跳过: \(spiderURL.prefix(80))")
            }
        }

        // 2. 【改造】按模式分类处理所有站点（双模式支持）
        var jsSpiderLoaded = 0
        var jsSpiderFailed = 0
        let baseURL = subManager.activeURL ?? ""

        // 收集需要加载的 JS 蜘蛛站点
        var jsSitesToLoad: [(site: SiteConfig, resolvedURL: String)] = []
        // 【新增】收集 API 模式的 type=3 站点，后续加入 allSites
        var apiSitesToAdd: [SiteConfig] = []

        for site in config.sites where site.api != nil && !site.api!.isEmpty {
            let mode = resolveSiteMode(site: site)

            switch mode {
            case .jsSpider:
                // 处理 JS 蜘蛛站点的 URL 解析（原有逻辑提取）
                let api = site.api!
                if api.hasPrefix("./") {
                    let fullURL: String
                    if let url = URL(string: baseURL) {
                        fullURL = url.deletingLastPathComponent().appendingPathComponent(api).absoluteString
                    } else {
                        fullURL = api
                    }
                    jsSitesToLoad.append((site: site, resolvedURL: fullURL))
                } else if !api.hasPrefix("http://") && !api.hasPrefix("https://") && api.hasSuffix(".js") {
                    // 纯 JS 文件名，从 baseURL 拼接
                    if let url = URL(string: baseURL) {
                        let fullURL = url.deletingLastPathComponent().appendingPathComponent(api).absoluteString
                        jsSitesToLoad.append((site: site, resolvedURL: fullURL))
                    }
                } else if api.hasPrefix("http://") || api.hasPrefix("https://") {
                    jsSitesToLoad.append((site: site, resolvedURL: api))
                }

            case .apiEndpoint:
                // 【新增】API 模式站点（含 type=3 的 HTTP CMS 接口）
                // 这些站点不需要创建 JS 引擎，直接加入 allSites 参与 HTTP 搜索
                apiSitesToAdd.append(site)
                print("[SpiderManager] API站点标记: \(site.name) (\(site.api ?? ""))")

            case .zhanyuan:
                // type=2 站源在后续单独处理
                break

            case .unsupported:
                print("[SpiderManager] 跳过不支持站点: \(site.name) (type=\(site.type), api=\(site.api ?? ""))")
            }
        }

        print("[SpiderManager] 发现 \(jsSitesToLoad.count) 个 JS 蜘蛛站点待加载")
        print("[SpiderManager] 发现 \(apiSitesToAdd.count) 个 API 模式站点待加入")

        // 限制最多加载 30 个蜘蛛（避免内存爆炸）
        for item in jsSitesToLoad.prefix(30) {
            let site = item.site
            let jsURL = item.resolvedURL
            guard let url = URL(string: jsURL) else { continue }
            let key = site.key.isEmpty ? site.name : site.key
            if engines[key] != nil { continue }

            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 15
                req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: req)
                if let jsCode = String(data: data, encoding: .utf8),
                   jsCode.count > 200,
                   (jsCode.contains("function ") || jsCode.contains("var ") || jsCode.contains("spider")) {
                    // 先加载 api 指向的 JS 框架
                    try await loadSpiderEngine(jsCode: jsCode, key: key)

                    // 如果站点有 ext 字段，加载 ext（drpy 系列站点配置）
                    if let ext = site.ext, !ext.isEmpty {
                        let extTrimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines)
                        if extTrimmed.hasPrefix("http://") || extTrimmed.hasPrefix("https://") {
                            // ext 是 URL，下载并加载
                            print("[SpiderManager] 加载 ext URL: \(extTrimmed.prefix(80))")
                            do {
                                let extData = try await downloadRawData(url: extTrimmed)
                                if let extCode = String(data: extData, encoding: .utf8), extCode.count > 50 {
                                    // 重新创建引擎，先加载框架再加载 ext 配置
                                    if let engine = engines[key] {
                                        try engine.loadScript(extCode)
                                        print("[SpiderManager] ✅ ext URL 加载成功: \(site.name)")
                                    }
                                }
                            } catch {
                                print("[SpiderManager] ext URL 加载失败: \(site.name) - \(error.localizedDescription)")
                            }
                        } else if extTrimmed.contains("function ") || extTrimmed.contains("var ") || extTrimmed.contains("let ") || extTrimmed.contains("const ") {
                            // ext 是内联 JS 代码，直接加载
                            print("[SpiderManager] 加载内联 ext JS: \(site.name)")
                            if let engine = engines[key] {
                                try engine.loadScript(extTrimmed)
                                print("[SpiderManager] ✅ 内联 ext 加载成功: \(site.name)")
                            }
                        } else {
                            // ext 可能是 JSON 配置，尝试作为配置注入
                            print("[SpiderManager] ext 不是 JS 代码，可能是配置: \(extTrimmed.prefix(60))")
                        }
                    }

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

        // 3. 加载 zhanyuan (type=2) 站源 — 用 cheerio + zhanyuan 引擎（支持双引擎回退）
        let zhanSites = config.sites.filter { $0.type == 2 && $0.api != nil && !$0.api!.isEmpty }
        print("[SpiderManager] 发现 \(zhanSites.count) 个 zhanyuan 站源")
        for site in zhanSites {
            let key = site.key.isEmpty ? site.name : site.key
            guard engines[key] == nil else { continue }
            let configJSON = site.ext ?? "{}"
            let escapedName = site.name.replacingOccurrences(of: "'", with: "\\'")
            // 使用 base64 编码传递 config，避免 XPath 规则中的特殊字符破坏 JSON 解析
            let configBase64 = configJSON.data(using: .utf8)?.base64EncodedString() ?? ""
            let zhanJS = """
            (function() {
                try {
                    var configJSON = atob('\(configBase64)');
                    var config = JSON.parse(configJSON);
                    config.name = config.name || '\(escapedName)';
                    config.searchUrl = config.searchUrl || '';
                    var spider = globalThis.__createZhanyuanSpider(config);
                    globalThis.__JS_SPIDER__ = spider;
                } catch(e) { print('[Zhanyuan] 创建蜘蛛失败: ' + e); }
            })();
            """
            
            // 尝试 JSC，失败回退到 QuickJS
            var zhanLoaded = false
            for engineType in [SpiderEngineType.javaScriptCore, .quickJS] {
                do {
                    let engine: SpiderEngineProtocol = engineType == .javaScriptCore ? JSSpiderEngine() : QJSSpiderEngine()
                    engine.onLog = { msg in print("[Zhanyuan|\(key)|\(engineType.displayName)] \(msg)") }
                    try await injectSpiderLibraries(engine: engine)
                    try engine.loadScript(zhanJS)
                    if engine.isSpiderReady {
                        engines[key] = engine
                        engineTypes[key] = engineType
                        if !subscribedSites.contains(key) { subscribedSites.append(key) }
                        jsSpiderLoaded += 1
                        print("[SpiderManager] ✅ zhanyuan 就绪 [\(engineType.displayName)]: \(site.name)")
                        zhanLoaded = true
                        break
                    } else {
                        try engine.registerSpider()
                        engines[key] = engine
                        engineTypes[key] = engineType
                        if !subscribedSites.contains(key) { subscribedSites.append(key) }
                        jsSpiderLoaded += 1
                        print("[SpiderManager] ✅ zhanyuan 注册成功 [\(engineType.displayName)]: \(site.name)")
                        zhanLoaded = true
                        break
                    }
                } catch {
                    print("[SpiderManager] ⚠️ zhanyuan \(engineType.displayName) 失败: \(site.name): \(error)")
                }
            }
            if !zhanLoaded {
                jsSpiderFailed += 1
                print("[SpiderManager] ❌ zhanyuan 全部引擎失败: \(site.name)")
            }
        }

        print("[SpiderManager] JS蜘蛛: 成功\(jsSpiderLoaded) 失败\(jsSpiderFailed), 总引擎: \(engines.count)")

        // 【新增】将 API 模式的 type=3 站点合并到 allSites
        // 这些站点会参与后续的 nativeSearch / fetchCategoryContent / nativeDetail
        if !apiSitesToAdd.isEmpty {
            let existingKeys = Set(allSites.map { $0.key })
            let newApiSites = apiSitesToAdd.filter { !existingKeys.contains($0.key) }
            if !newApiSites.isEmpty {
                self.allSites.append(contentsOf: newApiSites)
                loadedSiteCount = allSites.count
                print("[SpiderManager] ✅ 合并 \(newApiSites.count) 个 API 模式站点到 allSites，总计: \(loadedSiteCount)")
            }
        }

        // 【关键修复】将当前 allSites 中的 type=2 站源强制同步到 SQLite
        // 确保即使 SubscriptionManager.persistToDatabase 因各种原因未写入，数据库也有数据
        syncZhanyuanSitesToDatabase()

        await loadHomeData()
    }

    /// 将内存中的 type=2 站源同步到 SQLite
    private func syncZhanyuanSitesToDatabase() {
        let zhanSites = self.allSites.filter { $0.type == 2 && $0.api?.isEmpty == false }
        guard !zhanSites.isEmpty else {
            print("[SpiderManager] 无 type=2 站源需要同步到 SQLite")
            return
        }

        let now = Int64(Date().timeIntervalSince1970)
        let zhanyuanSites: [ZhanyuanSite] = zhanSites.compactMap { site in
            guard let api = site.api, !api.isEmpty else { return nil }
            let extJSON = site.ext ?? "{}"
            if let data = extJSON.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return ZhanyuanSite(
                    name: json["name"] as? String ?? site.name,
                    searchUrl: json["searchUrl"] as? String ?? api,
                    searchUA: json["searchUA"] as? String ?? "",
                    playUA: json["playUA"] as? String ?? "",
                    websearchurl: json["websearchurl"] as? String ?? "",
                    searchname: json["searchname"] as? String ?? "",
                    searchid: json["searchid"] as? String ?? "",
                    searchpic: json["searchpic"] as? String ?? "",
                    searchstarr: json["searchstarr"] as? String ?? "",
                    detaillist: json["detaillist"] as? String ?? "",
                    detailxl: json["detailxl"] as? String ?? "",
                    detailjs: json["detailjs"] as? String ?? "",
                    detailjsurl: json["detailjsurl"] as? String ?? "",
                    isActive: true,
                    updatedAt: now
                )
            }
            return ZhanyuanSite(
                name: site.name,
                searchUrl: api,
                searchUA: "",
                playUA: "",
                websearchurl: "",
                searchname: "",
                searchid: "",
                searchpic: "",
                searchstarr: "",
                detaillist: "",
                detailxl: "",
                detailjs: "",
                detailjsurl: "",
                isActive: true,
                updatedAt: now
            )
        }

        print("[SpiderManager] 强制同步 \(zhanyuanSites.count) 个 zhanyuan 站点到 SQLite")
        DatabaseManager.shared.saveZhanyuanSites(zhanyuanSites)
    }

    /// 加载蜘蛛 JS 到引擎 — 支持双引擎自动回退（JSC 优先，失败时尝试 QuickJS）
    private func loadSpiderEngine(jsCode: String, key: String = "builtin", preferredEngine: SpiderEngineType = .javaScriptCore) async throws {
        // 先尝试首选引擎
        let enginesToTry: [SpiderEngineType] = preferredEngine == .javaScriptCore
            ? [.javaScriptCore, .quickJS]
            : [.quickJS, .javaScriptCore]
        
        var lastError: Error?
        
        for engineType in enginesToTry {
            do {
                let engine = try await loadSpiderEngineWithType(jsCode: jsCode, key: key, engineType: engineType)
                engines[key] = engine
                engineTypes[key] = engineType
                if !subscribedSites.contains(key) { subscribedSites.append(key) }
                engineError = nil
                print("[SpiderManager] ✅ 蜘蛛就绪 [\(engineType.displayName)]: \(key)")
                return
            } catch {
                lastError = error
                print("[SpiderManager] ⚠️ \(engineType.displayName) 加载失败，尝试下一个引擎: \(error.localizedDescription)")
            }
        }
        
        let err = "蜘蛛注册失败 (\(key)): \(lastError?.localizedDescription ?? "所有引擎均失败")"
        engineError = err
        throw JSError(message: err)
    }
    
    /// 使用指定引擎类型加载蜘蛛
    private func loadSpiderEngineWithType(jsCode: String, key: String, engineType: SpiderEngineType) async throws -> SpiderEngineProtocol {
        let engine: SpiderEngineProtocol
        switch engineType {
        case .javaScriptCore:
            engine = JSSpiderEngine()
        case .quickJS:
            engine = QJSSpiderEngine()
        }
        
        engine.onLog = { msg in
            print("[SpiderEngine|\(key)|\(engineType.displayName)] \(msg)")
            if msg.contains("❌") || msg.contains("异常") || msg.contains("失败") {
                Task { @MainActor in self.engineError = msg }
            }
        }
        
        // 注入 TVBox 标准模板库
        try await injectSpiderLibraries(engine: engine)
        try engine.loadScript(jsCode)
        
        // 尝试注册
        if engine.isSpiderReady {
            return engine
        } else {
            try engine.registerSpider()
            return engine
        }
    }

    /// 注入 TVBox 标准 JS 库（模板引擎、网络桥接等）
    private func injectSpiderLibraries(engine: SpiderEngineProtocol) async throws {
        // 0. 浏览器兼容 polyfill（atob/btoa - QuickJS/JSC 没有这些）
        try engine.loadLibrary("""
        if (typeof atob === 'undefined') {
            atob = function(base64) {
                var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';
                var result = '';
                var buffer = 0, bits = 0;
                for (var i = 0; i < base64.length; i++) {
                    var c = chars.indexOf(base64[i]);
                    if (c === -1) continue;
                    buffer = (buffer << 6) | c;
                    bits += 6;
                    if (bits >= 8) {
                        bits -= 8;
                        result += String.fromCharCode((buffer >> bits) & 0xFF);
                    }
                }
                return result;
            };
        }
        """)
        // 1. net.js — 同步/异步 HTTP 请求封装
        try engine.loadLibrary("""
        let req = (url, options) => http(url, Object.assign({ async: false }, options));
        """)
        // 2. 加载 cheerio (HTML 解析器)
        if let cheerioPath = Bundle.main.path(forResource: "cheerio.min", ofType: "js"),
           let cheerioJs = try? String(contentsOfFile: cheerioPath, encoding: .utf8) {
            try engine.loadLibrary(cheerioJs)
            print("[SpiderManager] ✅ cheerio 已注入")
        }
        // 3. 加载 utils.js (TVBox 标准工具库)
        if let utilsPath = Bundle.main.path(forResource: "utils", ofType: "js", inDirectory: "js/lib"),
           let utilsJs = try? String(contentsOfFile: utilsPath, encoding: .utf8) {
            try engine.loadLibrary(utilsJs)
            print("[SpiderManager] ✅ utils.js 已注入")
        }
        // 4. 加载 similarity.js (相似度匹配库)
        if let simPath = Bundle.main.path(forResource: "similarity", ofType: "js", inDirectory: "js/lib"),
           let simJs = try? String(contentsOfFile: simPath, encoding: .utf8) {
            try engine.loadLibrary(simJs)
            print("[SpiderManager] ✅ similarity.js 已注入")
        }
        // 5. 模板引擎
        if let tmplPath = Bundle.main.path(forResource: "模板", ofType: "js"),
           let tmplJs = try? String(contentsOfFile: tmplPath, encoding: .utf8) {
            try engine.loadLibrary(tmplJs)
            print("[SpiderManager] ✅ 模板引擎已注入")
        }
        // 6. zhanyuan 蜘蛛引擎 (HTML 站源)
        if let zhanPath = Bundle.main.path(forResource: "zhanyuan_spider", ofType: "js"),
           let zhanJs = try? String(contentsOfFile: zhanPath, encoding: .utf8) {
            try engine.loadLibrary(zhanJs)
            print("[SpiderManager] ✅ zhanyuan 蜘蛛引擎已注入")
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
        // 尝试 JSC，失败回退到 QuickJS
        for engineType in [SpiderEngineType.javaScriptCore, .quickJS] {
            do {
                let engine: SpiderEngineProtocol = engineType == .javaScriptCore ? JSSpiderEngine() : QJSSpiderEngine()
                try await injectSpiderLibraries(engine: engine)
                try await engine.loadScriptFromURL(jsURL)
                if engine.isSpiderReady {
                    engines[site.key] = engine
                    engineTypes[site.key] = engineType
                    if !subscribedSites.contains(site.key) { subscribedSites.append(site.key) }
                    print("[SpiderManager] ✅ ext站点 [\(engineType.displayName)]: \(site.name)")
                    return
                } else {
                    try engine.registerSpider()
                    engines[site.key] = engine
                    engineTypes[site.key] = engineType
                    if !subscribedSites.contains(site.key) { subscribedSites.append(site.key) }
                    print("[SpiderManager] ✅ ext站点(注册) [\(engineType.displayName)]: \(site.name)")
                    return
                }
            } catch {
                print("[SpiderManager] ⚠️ ext站点 \(engineType.displayName) 失败: \(site.name): \(error)")
            }
        }
        print("[SpiderManager] ❌ ext站点全部引擎失败: \(site.name)")
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

        // 去重（已临时关闭以测试多源搜索结果）
        // var seen = Set<String>()
        // let originalCount = videos.count
        // videos = videos.filter { seen.insert($0.vodId.isEmpty ? $0.vodName : $0.vodId).inserted }
        // print("[SpiderManager] 去重前: \(originalCount)条, 去重后: \(videos.count)条")
        print("[SpiderManager] 去重已关闭，当前结果: \(videos.count)条")

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
                        // 智能去重：按 vodName+画质 分组，合并来源（已关闭，保留所有搜索结果）
                        // smartMerge(item: item, into: &allResults)
                        allResults.append(item)
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
        // 智能去重：合并原生搜索结果（已关闭，保留所有搜索结果）
        for item in nativeResults {
            // smartMerge(item: item, into: &allResults)
            allResults.append(item)
        }

        print("[SpiderManager] 搜索完成: QuickJS+原生 共 \(allResults.count) 条")
        return allResults.isEmpty ? nativeResults : allResults
    }

    /// 通过订阅源获取分类内容（调用 TVBox 标准的 ac=list 接口）
    func fetchCategoryContent(categoryTypeId: String, page: Int = 1) async -> [VodItem] {
        // 先尝试 QuickJS 引擎的 categoryContent
        var results: [VodItem] = []
        
        // 1. 尝试 JS 引擎
        for (key, engine) in engines {
            do {
                let result = try engine.callCategoryContent(tid: categoryTypeId, pg: page, extend: "{}")
                if let list = result.list, !list.isEmpty {
                    for var item in list {
                        if item.vodRemarks == nil || item.vodRemarks?.isEmpty == true {
                            item.vodRemarks = key
                        }
                        results.append(item)
                    }
                    print("[SpiderManager] 分类[\(categoryTypeId)]引擎[\(key)]: \(list.count)条")
                }
            } catch {
                print("[SpiderManager] 引擎分类失败[\(key)]: \(error)")
            }
        }
        
        // 2. 原生 HTTP 兜底 - 调用 TVBox API 站点
        // 【改造】使用 resolveSiteMode 筛选 API 模式站点，更准确地识别可调用站点
        let apiSites = allSites.filter { site in
            let mode = resolveSiteMode(site: site)
            return mode == .apiEndpoint || site.type == 0 || site.type == 1
        }
        for site in apiSites {
            guard let api = site.api else { continue }
            let urlStr = api.hasSuffix("/") ? "\(api)at/json?ac=list&t=\(categoryTypeId)&pg=\(page)" : "\(api)/at/json?ac=list&t=\(categoryTypeId)&pg=\(page)"
            guard let url = URL(string: urlStr) else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let list = json["list"] as? [[String: Any]] {
                    let items = list.compactMap { dict -> VodItem? in
                        guard let vodName = dict["vod_name"] as? String ?? dict["name"] as? String else { return nil }
                        let vodId = dict["vod_id"] as? String ?? dict["id"] as? String ?? UUID().uuidString
                        return VodItem(
                            vodId: vodId,
                            vodName: vodName,
                            vodPic: dict["vod_pic"] as? String ?? dict["pic"] as? String ?? "",
                            vodRemarks: dict["vod_remarks"] as? String ?? dict["remarks"] as? String ?? site.name,
                            vodYear: dict["vod_year"] as? String ?? dict["year"] as? String,
                            vodArea: dict["vod_area"] as? String,
                            vodDirector: dict["vod_director"] as? String,
                            vodActor: dict["vod_actor"] as? String,
                            vodContent: dict["vod_content"] as? String
                        )
                    }
                    results.append(contentsOf: items)
                    print("[SpiderManager] 原生分类[\(site.name)]: \(items.count)条")
                }
            } catch {
                print("[SpiderManager] 原生分类请求失败[\(site.name)]: \(error)")
            }
        }
        
        return results
    }

    /// 流式搜索 — 每个站点搜完立刻回调，不等全部完成
    func searchStream(keyword: String, onBatch: @escaping ([VodItem]) -> Void, onLog: ((String) -> Void)? = nil) async {
        let encodedKW = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let log = onLog ?? { print("[searchStream] \($0)") }
        log("====== 开始流式搜索: \(keyword) ======")

        // 写入搜索历史
        DatabaseManager.shared.addSearchHistory(keyword: keyword)

        // 1. QuickJS 蜘蛛（每个引擎一个任务）
        log("QuickJS引擎: \(engines.count) 个")
        for (key, engine) in engines {
            do {
                if let items = try engine.callSearchContent(keyword: keyword, pg: 1).list, !items.isEmpty {
                    var tagged = items
                    for i in 0..<tagged.count {
                        if tagged[i].vodRemarks == nil || tagged[i].vodRemarks?.isEmpty == true {
                            tagged[i].vodRemarks = key
                        }
                    }
                    log("✅ QuickJS[\(key)] +\(tagged.count)条")
                    onBatch(tagged)
                } else {
                    log("⬜ QuickJS[\(key)] 0条")
                }
            } catch {
                log("❌ QuickJS[\(key)] 错误: \(error.localizedDescription.prefix(50))")
            }
        }

        // 1.5 zhanyuan 原生搜索（Swift + Kanna，从 SQLite 读取站点配置）
        await ZhanyuanSearchService.searchAllZhanyuan(keyword: keyword, onBatch: { items in
            if !items.isEmpty {
                onBatch(items)
            }
        }, onLog: { msg in
            log("zhanyuan: \(msg)")
        })

        // 2. 合并订阅源 + ibox内置源 + 兜底源
        struct Site { let name: String; let api: String }
        var sites: [Site] = []
        // 使用 self.allSites（包含 ibox_sources.json 加载的内置站）
        let spiderAllSites = self.allSites
        log("allSites: \(spiderAllSites.count) 个")
        // 【改造】扩展筛选条件：包含 type=0/1 以及 API 模式的 type=3 站点
        for s in spiderAllSites where s.api?.isEmpty == false {
            let mode = resolveSiteMode(site: s)
            if mode == .apiEndpoint || s.type == 0 || s.type == 1 {
                if let api = s.api {
                    sites.append(Site(name: s.name, api: api))
                }
            }
        }
        log("API模式站点: \(sites.count) 个")
        // 兜底源补充
        if fallbackEnabled {
            log("兜底站: \(allFallbackSites.count) 个")
            for fb in allFallbackSites {
                sites.append(Site(name: fb.name, api: fb.api))
            }
        }
        log("合计搜索站点: \(sites.count) 个")

        guard !sites.isEmpty else {
            log("⚠️ 无可用搜索站点，退出")
            return
        }

        // 3. 全部站点并发搜索（限制并发数20），每个站点完成立即回调
        let allSites = Array(sites)
        log("合计搜索站点: \(allSites.count) 个（全部并发）")
        var successCount = 0
        var failCount = 0
        var emptyCount = 0
        let maxConcurrent = 60
        await withTaskGroup(of: (name: String, items: [VodItem]?).self) { group in
            var runningCount = 0
            for site in allSites {
                if runningCount >= maxConcurrent {
                    if let result = await group.next() {
                        if let items = result.items, !items.isEmpty {
                            log("✅ \(result.name) +\(items.count)条")
                            successCount += 1
                            onBatch(items)
                        } else if result.items == nil {
                            log("❌ \(result.name) 请求失败")
                            failCount += 1
                        } else {
                            emptyCount += 1
                        }
                        runningCount -= 1
                    }
                }
                runningCount += 1
                group.addTask {
                    let result = await self.searchOneSite(name: site.name, api: site.api, keyword: encodedKW)
                    return (name: site.name, items: result)
                }
            }
            // 等待剩余任务完成
            for await result in group {
                if let items = result.items, !items.isEmpty {
                    log("✅ \(result.name) +\(items.count)条")
                    successCount += 1
                    onBatch(items)
                } else if result.items == nil {
                    log("❌ \(result.name) 请求失败")
                    failCount += 1
                } else {
                    emptyCount += 1
                }
            }
        }
        log("====== Stream完成: 成功\(successCount)/空\(emptyCount)/失败\(failCount) ======")
    }

    /// 根据 URL 域名查找匹配的 zhanyuan 站点配置
    /// 优先从 SQLite 查找，为空时从内存回退
    private func findZhanyuanSiteForURL(_ url: String) async -> ZhanyuanSite? {
        guard let urlObj = URL(string: url) else { return nil }
        let host = urlObj.host ?? ""

        // 1. 从 SQLite 查找
        let dbSites = DatabaseManager.shared.queryActiveZhanyuanSites()
        for site in dbSites {
            if let siteUrl = URL(string: site.searchUrl),
               siteUrl.host == host {
                return site
            }
        }

        // 2. 从内存回退（@Published 属性需要主线程）
        let spiderSites = await MainActor.run { self.allSites }
        for s in spiderSites where s.type == 2 {
            guard let api = s.api, !api.isEmpty else { continue }
            if let siteUrl = URL(string: api), siteUrl.host == host {
                // 从 ext 字段构建 ZhanyuanSite
                let extJSON = s.ext ?? "{}"
                if let data = extJSON.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return ZhanyuanSite(
                        name: json["name"] as? String ?? s.name,
                        searchUrl: json["searchUrl"] as? String ?? api,
                        searchUA: json["searchUA"] as? String ?? "",
                        playUA: json["playUA"] as? String ?? "",
                        websearchurl: json["websearchurl"] as? String ?? "",
                        searchname: json["searchname"] as? String ?? "",
                        searchid: json["searchid"] as? String ?? "",
                        searchpic: json["searchpic"] as? String ?? "",
                        searchstarr: json["searchstarr"] as? String ?? "",
                        detaillist: json["detaillist"] as? String ?? "",
                        detailxl: json["detailxl"] as? String ?? "",
                        detailjs: json["detailjs"] as? String ?? "",
                        detailjsurl: json["detailjsurl"] as? String ?? "",
                        isActive: true,
                        updatedAt: Int64(Date().timeIntervalSince1970)
                    )
                }
                return ZhanyuanSite(name: s.name, searchUrl: api)
            }
        }

        return nil
    }

    /// 通过引擎获取详情，失败时回退到原生 API 详情
    func getDetail(ids: String, name: String? = nil) async -> VodItem? {
        // 0. 如果 ids 是 HTTP URL，判断是 zhanyuan 站源还是网盘
        if ids.hasPrefix("http://") || ids.hasPrefix("https://") {
            // 0.1 检查是否匹配 zhanyuan 站点域名
            if let zhanyuanSite = await findZhanyuanSiteForURL(ids) {
                print("[SpiderManager] getDetail 检测到 zhanyuan 站源详情页: \(zhanyuanSite.name)")
                do {
                    let item = try await ZhanyuanSearchService.fetchDetail(detailUrl: ids, site: zhanyuanSite)
                    return item
                } catch {
                    print("[SpiderManager] ❌ zhanyuan 详情页解析失败: \(error.localizedDescription)")
                    // 继续尝试其他方式
                }
            }

            // 0.2 非 zhanyuan，走网盘解析
            print("[SpiderManager] getDetail 检测到详情页URL，走网盘解析: \(ids.prefix(80))")
            if let result = await resolveCloudPlay(from: ids) {
                // 把所有网盘链接编码到 vodPlayUrl 中
                if let linkData = try? JSONSerialization.data(withJSONObject: result.links.map { ["url": $0.url, "name": $0.name] }),
                   let linkJSON = String(data: linkData, encoding: .utf8) {
                    let item = VodItem(vodId: ids, vodName: result.siteName, vodPic: "",
                                       vodRemarks: "☁️网盘", vodPlayUrl: linkJSON)
                    return item
                }
            }
            print("[SpiderManager] ❌ 网盘详情页解析失败")
            return nil
        }
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

        // 清除数据库中的订阅源数据（zhanyuan、aphiyuan、subscription）
        let db = DatabaseManager.shared
        db.clearAllZhanyuanSites()
        db.clearAllApiYuanSites()
        db.clearAllSubscriptions()
        print("[SpiderManager] 已清除订阅源 \(url) 的数据库记录")

        // 彻底清空 SpiderManager 的站点数据
        allSites = []
        loadedSiteCount = 0
        // 清除残留数据：如果删除的是当前激活的订阅源，重新加载站点
        Task { [self] in
            // 重新加载剩下的订阅源（如果有的话）
            await loadSitesFromSubscription()
        }
    }

    /// 原生搜索 — 直接 HTTP 调可用 API，不经过 QuickJS
    /// 先遍历订阅源中的 type=1/0 站点，再用硬编码采集站兜底
    func nativeSearch(keyword: String) async -> [VodItem] {
        var allResults: [VodItem] = []
        let encodedKW = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword

        // ====== 搜索源 0: 遍历订阅源 API 模式站点（含 type=0/1 和 API 模式的 type=3） ======
        let subSites = subManager.allSites.filter { site in
            guard let api = site.api, !api.isEmpty else { return false }
            let mode = resolveSiteMode(site: site)
            return mode == .apiEndpoint || site.type == 0 || site.type == 1
        }

        // ====== 搜索源 1: 兜底采集 API（开关控制）======
        struct SearchSite { let name: String; let api: String }
        var mergedSites: [SearchSite] = []
        // 域名去重保持关闭（让所有站都参与搜索）

        for site in subSites {
            guard let api = site.api, !api.isEmpty else { continue }
            mergedSites.append(SearchSite(name: site.name, api: api))
        }
        // 兜底源：开关打开时补充（订阅源不足3个 或 直接补上）
        if fallbackEnabled {
            for fb in allFallbackSites {
                mergedSites.append(SearchSite(name: fb.name, api: fb.api))
            }
        }

        if mergedSites.isEmpty {
            print("[SpiderManager] nativeSearch 无可用站点")
            return []
        }

        print("[SpiderManager] nativeSearch 合并搜索站点 \(mergedSites.count) 个（订阅\(subSites.count) + 兜底）")

        // 分批并发搜索，每批10个，支持全部站点参与搜索
        let batchSize = 30
        let allSites = Array(mergedSites)
        for batchStart in stride(from: 0, to: allSites.count, by: batchSize) {
            let batch = Array(allSites[batchStart..<min(batchStart + batchSize, allSites.count)])
            await withTaskGroup(of: [VodItem]?.self) { group in
                for site in batch {
                    group.addTask {
                        await self.searchOneSite(name: site.name, api: site.api, keyword: encodedKW)
                    }
                }
                for await items in group {
                    if let items = items {
                        // 智能去重：按 vodName+画质 分组（已关闭，保留所有搜索结果）
                        // for item in items {
                        //     smartMerge(item: item, into: &allResults)
                        // }
                        allResults.append(contentsOf: items)
                    }
                }
            }
        }

        print("[SpiderManager] nativeSearch 完成: \(allResults.count) 条")
        return allResults
    }

    /// 搜索单个 API 站点
    private func searchOneSite(name: String, api: String, keyword: String) async -> [VodItem]? {
        // 构造搜索URL：兼容多种API格式
        let searchURL: String
        if api.hasSuffix("=") || api.hasSuffix("&") {
            // api 已含查询参数（如 apiyuan 的 searchurl），直接拼关键词
            searchURL = api + keyword
        } else if api.hasSuffix("?") {
            searchURL = api + "wd=" + keyword
        } else if api.contains("?") {
            searchURL = api + "&wd=" + keyword
        } else if api.hasSuffix("/search") || api.hasSuffix("/search.html") {
            // 搜索页路径，尝试 wd 参数
            searchURL = api + "?wd=" + keyword
        } else if api.contains("/api/v1/video/search") || api.contains("/appapi/searchList") {
            // 非标准 API 路径
            searchURL = api + "?keyword=" + keyword
        } else {
            // 默认苹果CMS格式
            searchURL = api + "?ac=videolist&wd=" + keyword
        }

        guard let url = URL(string: searchURL) else {
            print("[SpiderManager] nativeSearch \(name) URL无效: \(searchURL.prefix(80))")
            return nil
        }

        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["list"] as? [[String: Any]], !list.isEmpty {
                let items = list.map { Self.makeVodItem(from: $0, siteName: name) }
                print("[SpiderManager] nativeSearch \(name): \(items.count) 条")
                return items
            }
        } catch {
            print("[SpiderManager] nativeSearch \(name) 失败: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - 网盘资源专用搜索（独立通道）
    /// 只搜索网盘资源站（video_sources.json 中的 HTML 网页站点）
    /// 返回的 VodItem.vodId 存的是详情页完整 URL，播放时直接抓取解析
    func cloudSearch(keyword: String, onLog: ((String) -> Void)? = nil) async -> [VodItem] {
        var results: [VodItem] = []
        let encodedKW = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        let log = onLog ?? { print("[cloudSearch] \($0)") }
        log("====== cloudSearch: \(keyword) ======")
        
        // 从配置中读取网盘资源站列表
        // 现在的 video_sources.json 是本地的，也可以内置信得过的网盘站
        let cloudSites: [(name: String, searchURL: String, detailBase: String)] = [
            ("木偶影视", "https://666.666291.xyz/index.php/vod/search.html?wd=", "https://666.666291.xyz"),
            ("多多资源", "https://tv.yydsys.top/index.php/vod/search.html?wd=", "https://tv.yydsys.top"),
            ("至臻影视", "http://www.miqk.cc/index.php/vod/search.html?wd=", "http://www.miqk.cc"),

            ("飞猫影视", "http://feimo.fun/index.php/vod/search.html?wd=", "http://feimo.fun"),
            ("2小盘", "https://www.2xiaopan.top/index.php/vod/search.html?wd=", "https://www.2xiaopan.top"),
            ("430520", "https://by1.430520.xyz/index.php/vod/search.html?wd=", "https://by1.430520.xyz"),
            ("92CJ云盘", "https://yun.92cj.com/yunbox/index.php/vod/search.html?wd=", "https://yun.92cj.com/yunbox"),
        ]

        for site in cloudSites {
            let fullURL = site.searchURL + encodedKW
            log("☁️ \(site.name) 请求中...")
            do {
                guard let url = URL(string: fullURL) else { continue }
                var req = URLRequest(url: url)
                req.timeoutInterval = 8
                req.setValue("Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: req)
                guard let html = String(data: data, encoding: .utf8) else { continue }
                
                // 从 HTML 中提取视频卡片：标题 + 详情页 URL + 封面
                let pattern = #"<a[^>]*href="(/index.php/vod/detail/id/(\d+)\.html)"[^>]*>([^<]+)</a>"#
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
                let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
                
                var siteCount = 0
                for match in matches {
                    guard match.numberOfRanges >= 4 else { continue }
                    let hrefRange = match.range(at: 1)
                    let idRange = match.range(at: 2)
                    let nameRange = match.range(at: 3)
                    guard hrefRange.location != NSNotFound, nameRange.location != NSNotFound,
                          let hRange = Range(hrefRange, in: html),
                          let nRange = Range(nameRange, in: html) else { continue }
                    let detailPath = String(html[hRange])
                    var title = String(html[nRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    // 过滤掉菜单项
                    if title.count < 2 || title.hasPrefix("首页") || title.hasPrefix("网址") || title.hasPrefix("APP") { continue }
                    
                    // 尝试提取封面图
                    var pic = ""
                    // 找当前卡片附近的图片
                    let picPattern = #"<img[^>]*src="([^"]+)"[^>]*>"#
                    // 简化：从页面上找第一张 poster 或封面
                    if let picRegex = try? NSRegularExpression(pattern: #"data-original="([^"]+)"#),
                       let picMatch = picRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                       let pRange = Range(picMatch.range(at: 1), in: html) {
                        pic = String(html[pRange])
                    }
                    if pic.isEmpty,
                       let picRegex = try? NSRegularExpression(pattern: #"<img[^>]*class="[^"]*lazy[^"]*"[^>]*data-src="([^"]+)"#),
                       let picMatch = picRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                       let pRange = Range(picMatch.range(at: 1), in: html) {
                        pic = String(html[pRange])
                    }
                    
                    let detailURL = site.detailBase + detailPath
                    let item = VodItem(vodId: detailURL, vodName: title, vodPic: pic, vodRemarks: site.name)
                    // 智能去重（已关闭，保留所有搜索结果）
                    // smartMerge(item: item, into: &results)
                    results.append(item)
                    siteCount += 1
                }
                print("[SpiderManager] cloudSearch \(site.name): \(siteCount) 条")
                log("☁️ ✅ \(site.name) +\(siteCount)条")
            } catch {
                log("☁️ ❌ \(site.name) 失败")
                print("[SpiderManager] cloudSearch \(site.name) 失败: \(error.localizedDescription)")
            }
        }
        print("[SpiderManager] ====== cloudSearch 完成: \(results.count) 条（智能去重后） ======")
        return results
    }

    /// 网盘资源详情解析（从详情页 HTML 中提取所有网盘链接+标题）
    func resolveCloudPlay(from detailURL: String) async -> (links: [(url: String, name: String)], siteName: String)? {
        print("[SpiderManager] resolveCloudPlay: \(detailURL)")
        if let cached = cloudPlayCache[detailURL], cached.expiresAt > Date(), !cached.links.isEmpty {
            print("[SpiderManager] resolveCloudPlay 命中缓存: \(cached.links.count) 条")
            return (cached.links, cached.siteName)
        }
        guard let url = URL(string: detailURL) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Mozilla/5.0 (Linux; Android 12; Pixel 6) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let html = String(data: data, encoding: .utf8) else {
                // 尝试 GBK 编码
                if let gbkData = try? NSString(data: data, encoding: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))) as String? {
                    let result = try await parseCloudHTML(html: gbkData)
                    if let result { cacheCloudPlay(result, for: detailURL) }
                    return result
                }
                print("[SpiderManager] ❌ 编码错误")
                return nil
            }
            let result = try await parseCloudHTML(html: html)
            if let result { cacheCloudPlay(result, for: detailURL) }
            return result
        } catch {
            print("[SpiderManager] resolveCloudPlay 失败: \(error.localizedDescription)")
            return nil
        }
    }

    private func cacheCloudPlay(_ result: (links: [(url: String, name: String)], siteName: String), for detailURL: String) {
        cloudPlayCache[detailURL] = (result.links, result.siteName, Date().addingTimeInterval(30 * 60))
        if cloudPlayCache.count > 100 {
            let now = Date()
            cloudPlayCache = cloudPlayCache.filter { $0.value.expiresAt > now }
        }
    }

    private func parseCloudHTML(html: String) async -> (links: [(url: String, name: String)], siteName: String)? {
        // 提取视频名称
        var videoName = ""
        if let titleRegex = try? NSRegularExpression(pattern: #"<h1[^>]*class="[^"]*page-title[^"]*"[^>]*>([^<]+)"#),
           let m = titleRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(m.range(at: 1), in: html) {
            videoName = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if videoName.isEmpty,
           let titleRegex = try? NSRegularExpression(pattern: #"<title>([^<]+)"#),
           let m = titleRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           let r = Range(m.range(at: 1), in: html) {
            videoName = String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-.*$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }

        // 提取所有网盘分享链接（去重），并识别网盘类型
        let panPatterns: [(pattern: String, driveName: String)] = [
            (#"(https?://115cdn\.com/s/[^\s\"<>']*)"#, "115网盘"),
            (#"(https?://(?:www\.)?(?:aliyundrive\.com|alipan\.com)/s/[^\s\"<>']*)"#, "阿里云盘"),
            (#"(https?://pan\.quark\.cn/s/[^\s\"<>']*)"#, "夸克网盘"),
            (#"(https?://pan\.baidu\.com/s/[^\s\"<>']*)"#, "百度网盘"),
            (#"(https?://(?:drive|pan)\.uc\.cn/s/[^\s\"<>']*)"#, "UC网盘"),
            (#"(https?://yun\.139\.com/[^\s\"<>']*)"#, "天翼云盘"),
            (#"(https?://yun\.139\.com/share(?:web|wap)/#/[wm]/i[/?][^\s\"<>']*)"#, "天翼云盘分享"),
            (#"(https?://www\.123[a-z0-9]+\.com/s/[a-zA-Z0-9\-]+)"#, "123云盘"),
        ]

        var allLinks: [(url: String, name: String)] = []
        var seenURLs = Set<String>()

        for (pattern, driveName) in panPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for match in matches {
                if let r = Range(match.range(at: 1), in: html) {
                    let panURL = String(html[r])
                    if !seenURLs.contains(panURL) {
                        seenURLs.insert(panURL)
                        var desc = driveName
                        let pos = match.range(at: 1).location
                        let start = Int(max(0, Int(pos) - 60))
                        let len = min(Int(pos) + 80, html.count) - start
                        if start >= 0, start + len <= html.count {
                            let around = String(html[html.index(html.startIndex, offsetBy: start)..<html.index(html.startIndex, offsetBy: start + len)])
                            if let qualityRegex = try? NSRegularExpression(pattern: #"(4K|1080[Pp]|720[Pp]|蓝光|高清|国语|粤语|中字|原盘|REMUX|HDR|60帧|DV)"#),
                               let qMatch = qualityRegex.firstMatch(in: around, range: NSRange(around.startIndex..., in: around)),
                               let qRange = Range(qMatch.range(at: 1), in: around) {
                                desc = "\(String(around[qRange]))·\(driveName)"
                            }
                        }
                        allLinks.append((panURL, desc))
                    }
                }
            }
        }

        if allLinks.isEmpty {
            print("[SpiderManager] ❌ 未找到网盘链接")
            return nil
        }
        print("[SpiderManager] ✅ 找到 \(allLinks.count) 个网盘链接: \(allLinks.map { $0.name })")
        return (allLinks, videoName.isEmpty ? "网盘资源" : videoName)
    }

    /// 解析单个网盘分享链接为播放地址
    func resolvePanURL(_ panURL: String) async -> (url: String, headers: [String: String])? {
        guard let driveType = CloudDriveManager.detectDrive(from: panURL) else {
            print("[SpiderManager] ❌ resolvePanURL: 无法识别网盘类型: \(panURL.prefix(40))")
            return nil
        }
        print("[SpiderManager] 🔍 检测到网盘类型: \(driveType.displayName)")
        let tokens = CloudDriveManager.shared.tokens(for: driveType)
        guard let token = tokens.first else {
            print("[SpiderManager] ⚠️ 未配置 \(driveType.displayName) Token，请到设置中配置")
            return (panURL, [:])
        }
        print("[SpiderManager] ✅ 获取到 \(driveType.displayName) Token: \(token.name)")
        do {
            print("[SpiderManager] ⏳ 正在调用 \(driveType.displayName) API 解析播放地址...")
            let result = try await CloudDriveManager.shared.resolvePlayURL(from: panURL)
            print("[SpiderManager] ✅ \(driveType.displayName) 解析成功! 播放地址: \(result.url.prefix(80))...")
            if !result.headers.isEmpty {
                print("[SpiderManager] 📋 请求头: \(result.headers.keys.joined(separator: ", "))")
            }
            return (result.url, result.headers)
        } catch let error as DriveError {
            print("[SpiderManager] ❌ \(driveType.displayName) 解析失败: \(error.localizedDescription)")
            if case .notImplemented = error {
                print("[SpiderManager] 💡 提示: Token 无效或已过期，请在设置中重新配置 \(driveType.displayName) Token")
            }
            return nil
        } catch {
            print("[SpiderManager] ❌ \(driveType.displayName) 解析异常: \(error.localizedDescription)")
            return nil
        }
    }

    /// 通过订阅源的 type=1 站点获取详情+播放地址
    /// 先用 ids 查，失败则用 name 搜索匹配
    func nativeDetail(ids: String, name: String? = nil) async -> VodItem? {
        let apiSites = subManager.apiSites
        // 【改造】扩展筛选条件：包含 API 模式的 type=3 站点
        let allApiSites = allSites.filter { site in
            guard let api = site.api, !api.isEmpty else { return false }
            let mode = resolveSiteMode(site: site)
            return mode == .apiEndpoint || site.type == 0 || site.type == 1
        }
        // 如果 apiSites 为空，降级用 allApiSites
        let detailSites = apiSites.isEmpty ? allApiSites : apiSites

        if detailSites.isEmpty {
            print("[SpiderManager] nativeDetail 失败: 无可用的 type=1 站点")
            print("[SpiderManager] 可用站点总数: \(allSites.count)")
            print("[SpiderManager] apiSites: \(apiSites.count)")
            return nil
        }

        print("[SpiderManager] nativeDetail: ids=\(ids), name=\(name ?? "nil"), 可用站点=\(detailSites.count)个")

        for site in detailSites {
            guard let siteApi = site.api, !siteApi.isEmpty else { continue }
            // 剥离查询参数，取纯基地址（兼容 apiyuan 的 ?ac=detail&wd= 格式）
            let baseUrl: String
            if let qIndex = siteApi.firstIndex(of: "?") {
                baseUrl = String(siteApi[..<qIndex])
            } else if siteApi.hasSuffix("/") {
                baseUrl = String(siteApi.dropLast())
            } else {
                baseUrl = siteApi
            }
            
            // 尝试多种API格式
            let apiFormats = [
                "\(baseUrl)?ac=videolist&ids=\(ids)",
                "\(baseUrl)?ac=detail&ids=\(ids)",
                "\(baseUrl)?ac=videolist&ids=\(ids)&pg=1"
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
               let searchURL = URL(string: "\(baseUrl)?ac=detail&wd=\(encN)") {
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
        // 0. 【新增】兼容 TVBox 特殊播放格式前缀
        var actualUrl = playPageUrl
        if playPageUrl.hasPrefix("parse://") || playPageUrl.hasPrefix("json://") {
            actualUrl = String(playPageUrl.dropFirst(8))
            print("[SpiderManager] 检测到 TVBox 前缀，解析后: \(actualUrl.prefix(80))")
        }

        // 1. 检查是否已经是直链
        if actualUrl.hasSuffix(".m3u8") || actualUrl.hasSuffix(".mp4") {
            return actualUrl
        }

        // 1.5 B站直链解析
        if actualUrl.contains("bilibili.com") || actualUrl.contains("b23.tv") {
            let bvid = extractBilibiliID(from: playPageUrl)
            if !bvid.isEmpty {
                let bUrl = "https://api.bilibili.com/x/player/playurl?bvid=\(bvid)&type=mp4&platform=html5"
                if let data = try? await URLSession.shared.data(from: URL(string: bUrl)!).0,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let durl = json["data"] as? [String: Any] {
                    // 尝试提取 durl 或 stream 中的视频地址
                    if let durlList = durl["durl"] as? [[String: Any]], let first = durlList.first, let videoUrl = first["url"] as? String {
                        return videoUrl
                    }
                }
            }
        }

        print("[SpiderManager] 开始解析播放页：\(actualUrl.prefix(60))...")

        // 2. 优先使用自定义解析器
        if !customParsers.isEmpty {
            print("[SpiderManager] 尝试自定义解析器，共\(customParsers.count)个")
            for (idx, parser) in customParsers.enumerated() {
                print("[SpiderManager] [\(idx+1)/\(customParsers.count)] 尝试：\(parser.name) - \(parser.url)")
                if let parsedUrl = await tryParser(parser.url, url: actualUrl) {
                    print("[SpiderManager] ✅ 自定义解析器成功：\(parser.name)")
                    return parsedUrl
                }
            }
        }

        // 3. 优先使用订阅源的解析器（次优先）
        if !subManager.parses.isEmpty {
            print("[SpiderManager] 使用订阅源解析器，共\(subManager.parses.count)个")
            for (idx, parse) in subManager.parses.enumerated() {
                print("[SpiderManager] [\(idx+1)/\(subManager.parses.count)] 尝试：\(parse.name) - \(parse.url)")
                if let parsedUrl = await tryParser(parse.url, url: actualUrl) {
                    print("[SpiderManager] ✅ 订阅源解析器成功：\(parse.name)")
                    print("[SpiderManager] 解析结果：\(parsedUrl.prefix(80))...")
                    return parsedUrl
                }
            }
        }

        // 4. 尝试直接请求播放页提取 m3u8
        if let directUrl = await extractDirectPlayURL(from: actualUrl) {
            print("[SpiderManager] ✅ 从播放页直接提取成功：\(directUrl.prefix(80))...")
            return directUrl
        }

        // 4.5 WKWebView 客户端解析回退（最后手段）
        if let wkResult = await tryWKWebViewParse(originalURL: actualUrl) {
            return wkResult
        }

        print("[SpiderManager] ❌ 所有解析器均失败")
        return nil
    }

    // MARK: - WKWebView 客户端解析回退
    private func tryWKWebViewParse(originalURL: String) async -> String? {
        return await withCheckedContinuation { continuation in
            WKWebViewParser.shared.parse(url: originalURL, parserType: .jsParser(jsURL: "https://jx.xmflv.com/?url=")) { result in
                if let result = result, !result.isEmpty {
                    // 尝试从结果中提取视频地址
                    if let urlRange = result.range(of: "https?://[^\\s\"'<>]+\\.m3u8[^\\s\"'<>]*", options: .regularExpression) {
                        continuation.resume(returning: String(result[urlRange]))
                    } else if let urlRange = result.range(of: "https?://[^\\s\"'<>]+\\.mp4[^\\s\"'<>]*", options: .regularExpression) {
                        continuation.resume(returning: String(result[urlRange]))
                    } else {
                        continuation.resume(returning: nil)
                    }
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - B站直链辅助方法
    private func extractBilibiliID(from url: String) -> String {
        // BV号格式
        if let range = url.range(of: "BV[A-Za-z0-9]+") {
            return String(url[range])
        }
        // b23.tv 短链接需要重定向获取真实URL
        if url.contains("b23.tv") {
            // 返回空，让解析器处理
            return ""
        }
        // avid 格式
        if let range = url.range(of: "/video/av(\\d+)", options: .regularExpression) {
            let match = String(url[range])
            if let avRange = match.range(of: "\\d+", options: .regularExpression) {
                return String(match[avRange])
            }
        }
        return ""
    }

    private func tryParser(_ parserBase: String, url: String) async -> String? {
        let parseUrl = "\(parserBase)\(url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url)"

        guard let requestUrl = URL(string: parseUrl) else { return nil }

        do {
            var request = URLRequest(url: requestUrl)
            request.timeoutInterval = 8
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

            let (data, _) = try await URLSession.shared.data(for: request)

            // 尝试从响应中提取 m3u8/mp4 链接
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

                        // 清理 JSON 格式的 URL
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
            print("[SpiderManager] 解析器请求失败：\(error.localizedDescription)")
        }

        return nil
    }
    
    /// 直接从播放页提取 m3u8/mp4链接
    private func extractDirectPlayURL(from playUrl: String) async -> String? {
        guard let url = URL(string: playUrl) else { return nil }
        
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            // 如果是 m3u8/mp4 直接返回
            if let mimeType = (response as? HTTPURLResponse)?.allHeaderFields["Content-Type"] as? String {
                if mimeType.contains("application/vnd.apple.mpegurl") || mimeType.contains("video/mp4") {
                    return playUrl
                }
            }
            
            // 尝试从 HTML 中提取
            if let html = String(data: data, encoding: .utf8) {
                let patterns = [
                    "https?://[^\\s\"'<>]+\\.m3u8[^\\s\"'<>]*",
                    "https?://[^\\s\"'<>]+\\.mp4[^\\s\"'<>]*",
                    "player\\.src\\(\\{\\s*src:\\s*['\"]([^'\"]+)['\"]",
                    "video\\.src\\(\\{\\s*src:\\s*['\"]([^'\"]+)['\"]",
                    "config *= *\\{[^}]*url:\\s*['\"]([^'\"]+)['\"]",
                    "\"playUrl\":\\s*\"([^\"]+)\"",
                    "data-play-url=\"([^\"]+)\""
                ]
                
                for pattern in patterns {
                    if let regex = try? NSRegularExpression(pattern: pattern),
                       let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
                        let range = Range(match.range(at: 1), in: html) ?? Range(match.range(at: 0), in: html)
                        if let r = range {
                            var result = String(html[r])
                            // 清理结果
                            if result.hasPrefix("\"") && result.hasSuffix("\"") {
                                result = String(result.dropFirst().dropLast())
                            }
                            if result.hasPrefix("http") {
                                print("[SpiderManager] 直接从 HTML 提取：\(result.prefix(80))")
                                return result
                            }
                            // 相对路径处理
                            if result.hasPrefix("//") {
                                result = "https:" + result
                                return result
                            }
                            if result.hasPrefix("/") && url.host != nil {
                                if let scheme = url.scheme {
                                    result = "\(scheme)://\(url.host ?? "")" + result
                                    return result
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            print("[SpiderManager] 直接提取失败：\(error.localizedDescription)")
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

    nonisolated private func fetchDetail(url: URL, siteName: String) async -> VodItem? {
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 5
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
                _ = String(rawStr.prefix(500))
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
            }
        } catch {
            print("[SpiderManager] fetchDetail(ids) \(siteName) 失败: \(error.localizedDescription)")
        }
        return nil
    }

    nonisolated private func fetchDetailFromSearchList(url: URL, siteName: String, targetName: String) async -> VodItem? {
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

    nonisolated private static func makeVodItem(from dict: [String: Any], siteName: String) -> VodItem {
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

    // MARK: - 智能去重方法

    /// 智能合并搜索结果：按 vodName+画质 分组，合并来源站点名
    private func smartMerge(item: VodItem, into results: inout [VodItem]) {
        // 提取画质标记
        let quality = extractQuality(from: item.vodRemarks ?? "")
        // 生成去重key：名称 + 画质（如果画质不同则视为不同条目）
        let dedupKey = "\(item.vodName)_\(quality)"

        if let existIdx = results.firstIndex(where: { "\($0.vodName)_\(extractQuality(from: $0.vodRemarks ?? ""))" == dedupKey }) {
            // 合并来源
            var existing = results[existIdx]
            let existingRemarks = existing.vodRemarks ?? ""
            let newRemarks = item.vodRemarks ?? ""
            // 合并来源站点名（去重）
            var sources = Set<String>()
            for r in existingRemarks.components(separatedBy: ",") {
                let s = r.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { sources.insert(s) }
            }
            for r in newRemarks.components(separatedBy: ",") {
                let s = r.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { sources.insert(s) }
            }
            existing.vodRemarks = sources.joined(separator: ", ")
            // 保留更高画质的备注
            if qualityRank(newRemarks) > qualityRank(existingRemarks) {
                existing.vodRemarks = newRemarks
            }
            // 保留更高画质的封面（vodPic是let常量，不能修改，跳过）
            // if !item.vodPic.isEmpty && qualityRank(newRemarks) > qualityRank(existingRemarks) {
            //     existing.vodPic = item.vodPic
            // }
            results[existIdx] = existing
        } else {
            results.append(item)
        }
    }

    /// 从备注中提取画质标记
    private func extractQuality(from remarks: String) -> String {
        if remarks.contains("4K") { return "4K" }
        if remarks.contains("1080P") || remarks.contains("1080p") { return "1080P" }
        if remarks.contains("720P") || remarks.contains("720p") { return "720P" }
        if remarks.contains("蓝光") { return "蓝光" }
        if remarks.contains("高清") { return "高清" }
        return "其他"
    }

    /// 画质优先级排名（数值越高画质越好）
    private func qualityRank(_ remarks: String) -> Int {
        if remarks.contains("4K") { return 6 }
        if remarks.contains("1080P") || remarks.contains("1080p") { return 5 }
        if remarks.contains("蓝光") { return 4 }
        if remarks.contains("720P") || remarks.contains("720p") { return 3 }
        if remarks.contains("高清") { return 2 }
        return 1
    }
}
