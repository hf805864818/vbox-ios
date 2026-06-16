import Foundation

/// 站点加载诊断结果
struct SiteDiagnosticResult: Identifiable {
    let id = UUID()
    let siteKey: String
    let siteName: String
    let type: Int
    let api: String?
    let searchable: Int?
    let status: SiteStatus
    let errorMessage: String?
    let engineLoaded: Bool
    let canSearch: Bool
}

enum SiteStatus: String, CaseIterable {
    case loaded = "已加载"
    case engineReady = "引擎就绪"
    case apiOnly = "仅API"
    case noApi = "无API地址"
    case downloadFailed = "下载失败"
    case invalidContent = "内容无效"
    case registerFailed = "注册失败"
    case unknown = "未知"
    case skipped = "已跳过"
    
    var icon: String {
        switch self {
        case .loaded, .engineReady: return "✅"
        case .apiOnly: return "📡"
        case .noApi: return "❌"
        case .downloadFailed: return "🌐"
        case .invalidContent: return "📄"
        case .registerFailed: return "🔧"
        case .unknown: return "❓"
        case .skipped: return "⏭️"
        }
    }
}

/// 站点诊断管理器 — 帮助用户了解每个接口的状态
@MainActor
class SiteDiagnosticsManager: ObservableObject {
    static let shared = SiteDiagnosticsManager()
    
    @Published var results: [SiteDiagnosticResult] = []
    @Published var isDiagnosing = false
    @Published var summary: DiagnosticSummary?
    
    struct DiagnosticSummary {
        let total: Int
        let engineReady: Int
        let apiOnly: Int
        let failed: Int
        let skipped: Int
        let searchableCount: Int
    }
    
    private init() {}
    
    /// 对 SpiderManager 中的所有站点进行诊断
    func diagnose(spiderManager: SpiderManager) async {
        isDiagnosing = true
        defer { isDiagnosing = false }
        
        var diagnostics: [SiteDiagnosticResult] = []
        let sites = spiderManager.allSites
        
        for site in sites {
            let result = await diagnoseSite(site, spiderManager: spiderManager)
            diagnostics.append(result)
        }
        
        results = diagnostics
        
        let engineReady = diagnostics.filter { $0.status == .engineReady }.count
        let apiOnly = diagnostics.filter { $0.status == .apiOnly }.count
        let failed = diagnostics.filter { [.downloadFailed, .invalidContent, .registerFailed, .noApi].contains($0.status) }.count
        let skipped = diagnostics.filter { $0.status == .skipped }.count
        let searchable = diagnostics.filter { $0.canSearch }.count
        
        summary = DiagnosticSummary(
            total: diagnostics.count,
            engineReady: engineReady,
            apiOnly: apiOnly,
            failed: failed,
            skipped: skipped,
            searchableCount: searchable
        )
    }
    
    private func diagnoseSite(_ site: SiteConfig, spiderManager: SpiderManager) async -> SiteDiagnosticResult {
        let key = site.key.isEmpty ? site.name : site.key
        let hasEngine = spiderManager.hasEngine(forKey: key)
        
        // 判断搜索能力
        var canSearch = false
        var status: SiteStatus = .unknown
        var errorMsg: String? = nil
        
        switch site.type {
        case 0, 1:
            // API 采集站
            if let api = site.api, !api.isEmpty, api.hasPrefix("http") {
                canSearch = true
                status = .apiOnly
            } else {
                status = .noApi
                errorMsg = "API地址为空或无效"
            }
            
        case 2:
            // zhanyuan 站源
            if hasEngine {
                canSearch = true
                status = .engineReady
            } else {
                status = .registerFailed
                errorMsg = "zhanyuan 引擎未成功加载（缺少 cheerio/zhanyuan_spider.js 库文件）"
            }
            
        case 3:
            // JS 蜘蛛
            if hasEngine {
                canSearch = true
                status = .engineReady
            } else if let api = site.api, !api.isEmpty {
                if api.hasPrefix("http://") || api.hasPrefix("https://") {
                    // 尝试下载诊断
                    do {
                        var req = URLRequest(url: URL(string: api)!)
                        req.timeoutInterval = 10
                        let (data, response) = try await URLSession.shared.data(for: req)
                        let httpResp = response as? HTTPURLResponse
                        
                        if httpResp?.statusCode != 200 {
                            status = .downloadFailed
                            errorMsg = "HTTP \(httpResp?.statusCode ?? 0)，无法下载 JS 脚本"
                        } else if let jsCode = String(data: data, encoding: .utf8) {
                            if jsCode.count < 200 {
                                status = .invalidContent
                                errorMsg = "JS 代码太短(\(jsCode.count)字符)，可能不是有效蜘蛛脚本"
                            } else if !jsCode.contains("function ") && !jsCode.contains("spider") {
                                status = .invalidContent
                                errorMsg = "内容不包含 function/spider 关键字，可能不是 JS 脚本（可能是 jar 包或 HTML）"
                            } else {
                                status = .registerFailed
                                errorMsg = "JS 代码下载成功但引擎注册失败（可能缺少 __JS_SPIDER__ 导出，或依赖 cheerio/模板.js 等库）"
                            }
                        } else {
                            status = .invalidContent
                            errorMsg = "无法解码响应内容为字符串"
                        }
                    } catch {
                        status = .downloadFailed
                        errorMsg = "下载失败: \(error.localizedDescription)"
                    }
                } else {
                    status = .noApi
                    errorMsg = "api 不是 http/https URL: \(api)"
                }
            } else {
                status = .noApi
                errorMsg = "api 字段为空"
            }
            
        default:
            status = .unknown
            errorMsg = "未知类型 type=\(site.type)"
        }
        
        // 如果站点明确标记了 searchable=0，则覆盖搜索能力
        if site.searchable == 0 {
            canSearch = false
            errorMsg = (errorMsg ?? "") + " [searchable=0，已禁用搜索]"
        }
        
        return SiteDiagnosticResult(
            siteKey: key,
            siteName: site.name,
            type: site.type,
            api: site.api,
            searchable: site.searchable,
            status: status,
            errorMessage: errorMsg,
            engineLoaded: hasEngine,
            canSearch: canSearch
        )
    }
}

// MARK: - SpiderManager 扩展
extension SpiderManager {
    /// 检查是否有指定 key 的引擎
    func hasEngine(forKey key: String) -> Bool {
        return engines[key] != nil
    }
    
    /// 获取引擎加载统计
    var engineStats: (loaded: Int, total: Int) {
        return (engines.count, allSites.count)
    }
}
