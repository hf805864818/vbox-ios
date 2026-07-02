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
        // 强制加载 AliyunPlayer 动态框架，使 NSClassFromString("AliPlayer") 在运行时可用
        loadAliyunPlayerIfNeeded()
        DoubanImageProxyServer.shared.start()
        // 触发数据库初始化（建表 + 数据迁移）
        let _ = DatabaseManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// 运行时强制加载 AliyunPlayer 动态框架（解决 NSClassFromString 返回 nil 的问题）
private func loadAliyunPlayerIfNeeded() {
    guard NSClassFromString("AliPlayer") == nil else {
        print("[AliyunPlayer] ✅ AliPlayer 类已存在，无需加载")
        return
    }

    // 兜底：使用 dlopen 强制加载 framework 二进制
    let frameworkName = "AliyunPlayer"
    let candidates = [
        Bundle.main.bundlePath + "/Frameworks/\(frameworkName).framework/\(frameworkName)",
        Bundle.main.bundlePath + "/\(frameworkName).framework/\(frameworkName)",
        "@rpath/\(frameworkName).framework/\(frameworkName)"
    ]
    for path in candidates {
        let resolved = path.hasPrefix("@rpath") ? path : path
        if dlopen(resolved, RTLD_LAZY) != nil {
            print("[AliyunPlayer] dlopen 加载成功: \(resolved)")
            break
        }
    }

    if NSClassFromString("AliPlayer") != nil {
        print("[AliyunPlayer] ✅ 运行时 AliPlayer 类已可用")
    } else {
        print("[AliyunPlayer] ❌ 运行时仍无法找到 AliPlayer 类")
    }
}
