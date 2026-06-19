import SwiftUI
import UIKit

// MARK: - AppDelegate 用于控制屏幕方向
class VBoxAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return OrientationHelper.currentOrientationMask
    }
}

@main
struct VBoxApp: App {
    @UIApplicationDelegateAdaptor(VBoxAppDelegate.self) var appDelegate

    init() {
        DoubanImageProxyServer.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
