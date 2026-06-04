import SwiftUI
import Combine

/// 全局应用设置
class AppSettings: ObservableObject {
    @Published var isSpiderReady = false
    @Published var subscribedSites: [SiteConfig] = []
    @Published var selectedSiteKey: String?
    
    init() {}
}

/// 蜘蛛引擎全局管理器
class SpiderManager {
    static let shared = SpiderManager()
    
    let repository = SpiderRepository()
    
    var onLog: ((String) -> Void)?
    
    func initialize() async {
        repository.onLog = { [weak self] msg in
            DispatchQueue.main.async {
                print("[Spider] \(msg)")
                self?.onLog?(msg)
            }
        }
        
        // 加载测试蜘蛛脚本
        do {
            if let scriptURL = Bundle.main.url(forResource: "测试蜘蛛", withExtension: "js", subdirectory: "js/lib/native_bridge") {
                let script = try String(contentsOf: scriptURL)
                let engine = JSSpiderEngine()
                engine.onLog = { print("[JS引擎] \($0)") }
                try engine.loadScript(script)
                try engine.registerSpider()
                repository.registerEngine(siteKey: "test_site", engine: engine)
                
                DispatchQueue.main.async {
                    print("✅ SpiderManager 初始化完成")
                }
            }
        } catch {
            print("❌ SpiderManager 初始化失败: \(error)")
        }
    }
}
