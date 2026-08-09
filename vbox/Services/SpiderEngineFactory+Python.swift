//
//  SpiderEngineFactory+Python.swift
//  vbox
//
//  扩展 SpiderEngineFactory 以支持 Python Spider 引擎
//  使用方式：在 SpiderEngineFactory.swift 的 switch engineType 中添加一行
//
//  case "python", "py":
//      return try buildPythonEngine(api: api, key: key)
//

import Foundation

extension SpiderEngineFactory {
    
    // MARK: - 现有方法中需要添加的 case
    
    /*
     // ========== SpiderEngineFactory.swift 中的改动 ==========
     
     // 在 resolveSiteMode() 方法中添加（约第 143 行附近）：
     
     // 🆕 Python Spider: .py 结尾的 URL 识别为 Python 模式
     if api.lowercased().hasSuffix(".py") {
         return .pythonSpider
     }
     
     // ========== SiteMode 枚举中新增 case ==========
     
     enum SiteMode {
         case jsSpider
         case apiEndpoint
         case zhanyuan
         case pythonSpider    // 🆕 新增
         case unsupported
     }
     
     // ========== SpiderEngineFactory.buildEngine() switch 中添加 ==========
     
     case "python", "py":
         // Python Spider 引擎
         let localPath = resolvePythonScriptPath(api: api)
         let engine = PythonSpiderEngine(scriptPath: localPath, key: key)
         engine.onLog = { msg in
             print("[PythonSpider|\(key)] \(msg)")
         }
         return engine
     
     // ========== 新增辅助方法 ==========
     
     static func resolvePythonScriptPath(api: String) -> String {
         // 1. 如果 api 是绝对路径，直接返回
         if api.hasPrefix("/") && FileManager.default.fileExists(atPath: api) {
             return api
         }
         
         // 2. 如果是相对路径（如 "./sources/js/555dy.py"），
         //    解析到 Documents/remote_sources/ 缓存目录
         let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
         let cacheDir = docs.appendingPathComponent("remote_sources/spider_scripts")
         
         // 从 api 提取文件名
         let filename = URL(fileURLWithPath: api).lastPathComponent
         let localPath = cacheDir.appendingPathComponent(filename).path
         
         // 3. 如果缓存已存在，直接返回
         if FileManager.default.fileExists(atPath: localPath) {
             return localPath
         }
         
         // 4. 否则需要下载（由 SpiderManager 的 loadSitesFromSubscription 中处理）
         return localPath
     }
     
     // ========== 在 fetchHomeData() switch 中添加 ==========
     
     case .pythonSpider:
         return await fetchPythonSpiderHomeData(source: source)
     
     // ========== 新增方法 ==========
     
     static func fetchPythonSpiderHomeData(source: SourceDisplayItem) async -> SourceHomeData? {
         guard let key = source.engineKey,
               let engine = SpiderManager.shared.getEngine(forKey: key) as? PythonSpiderEngine else {
             return nil
         }
         
         do {
             let result = try engine.callHomeContent()
             return SourceHomeData(
                 sourceName: source.name,
                 categories: result.class ?? [],
                 recommended: result.list,
                 sourceType: source.category
             )
         } catch {
             print("[PythonSpider] 首页加载失败: \(error)")
             return nil
         }
     }
     */
}
