import SwiftUI

@main
struct VBoxApp: App {
    init() {
        DoubanImageProxyServer.shared.start()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    initQuickJS()
                }
        }
    }

    private func initQuickJS() {
        let engine = QJSSpiderEngine()
        engine.onLog = { print("[QuickJS] \($0)") }
        _ = engine.evaluateJS("1+1")
        print("✅ QuickJS 引擎就绪")
    }
}
