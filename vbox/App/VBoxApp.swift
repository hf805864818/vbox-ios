import SwiftUI

@main
struct VBoxApp: App {
    init() {
        DoubanImageProxyServer.shared.start()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
