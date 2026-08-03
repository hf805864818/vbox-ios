//
//  WelfareRemoteBootstrap.swift
//  vbox
//
//  Phase 2 方案 A：完全不动现有代码 — App 启动自动激活
//  作用：通过 Objective-C runtime 的 +load 机制，在 App 启动早期自动调用
//        WelfarePlatformConfigStore.shared.bootstrap()，完全不需要修改任何现有 .swift 文件。
//
//  实现原理：
//        Swift 没有 +load 等价，但 Objective-C 的 +load 在类加载时（早于 main）会被调用。
//        本文件定义一个 @objc 类 WelfareRemoteAutoLoader，其 +load 方法会：
//        1. dispatch_async 到 main queue
//        2. 调用 WelfarePlatformConfigStore.shared.bootstrap()
//
//  使用方法（用户操作）：
//        1. 把整个 WelfareRemote/ 目录加到 Xcode target
//        2. 无需修改任何现有代码
//        3. 编译运行即可：福利远程源自动 bootstrap，开关默认开
//
//  防御性设计：
//        - bootstrap() 内部已做幂等保护
//        - +load 在主线程之前调用，dispatch_async 到主线程执行
//        - 即使 +load 失败也不影响 App 启动（容错）
//

import Foundation
import UIKit

// MARK: - Objective-C +load 风格的全局初始化

/// 通过 Objective-C runtime 的 +load 机制，在 App 启动时立即激活福利远程源
@objc(WelfareRemoteAutoLoader)
final class WelfareRemoteAutoLoader: NSObject {

    /// Objective-C +load：在类加载时立即执行（早于 main，最早的执行时机）
    /// Swift 通过 @objc + class func load() 实现
    @objc class func load() {
        // 防御：仅在主 App target 中激活，不在 widget/extension 中激活
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            return
        }

        // 在主线程异步执行 bootstrap（+load 阶段不能阻塞）
        // 使用 @MainActor 保证 Swift 6 并发检查通过
        DispatchQueue.main.async {
            Task { @MainActor in
                WelfarePlatformConfigStore.shared.bootstrap()
                print("[WelfareRemote] ✅ App 启动自动 bootstrap 完成")
            }
        }
    }
}

// MARK: - 备用：UIApplicationDelegate swizzle 方式（如果 +load 失效）

/// 备用激活方式：通过 UIApplicationDelegate swizzle
/// 一般 +load 方式已经足够，本类仅作 fallback
@objc(WelfareRemoteAppDelegateSwizzler)
final class WelfareRemoteAppDelegateSwizzler: NSObject {

    @objc class func load() {
        // 同样仅在主 App 中激活
        guard Bundle.main.bundlePath.hasSuffix(".app") else {
            return
        }

        // 延迟到下一个 runloop 再 swizzle（确保主 AppDelegate 已加载）
        DispatchQueue.main.async {
            Self.installSwizzleIfNeeded()
        }
    }

    private static var didInstall = false

    private static func installSwizzleIfNeeded() {
        guard !didInstall else { return }
        didInstall = true

        // 通过 NSClassFromString 查找现有的 VBoxAppDelegate（不强引用）
        guard let cls = NSClassFromString("VBox.VBoxAppDelegate") ?? NSClassFromString("VBoxAppDelegate") else {
            print("[WelfareRemote] ⚠️ 未找到 VBoxAppDelegate，跳过 swizzle（+load 激活已生效，无需 swizzle）")
            return
        }

        // 找到 application(_:didFinishLaunchingWithOptions:) 方法
        let originalSelector = #selector(
            UIApplicationDelegate.application(_:didFinishLaunchingWithOptions:)
        )

        guard let originalMethod = class_getInstanceMethod(cls, originalSelector) else {
            print("[WelfareRemote] ⚠️ 未找到 didFinishLaunching，跳过 swizzle")
            return
        }

        // 注入我们的 swizzled 实现
        let swizzledSelector = #selector(
            WelfareRemoteAppDelegateSwizzler.swizzled_didFinishLaunching(_:launchOptions:)
        )

        // 添加 swizzled 方法到目标类
        let swizzledImp = class_getInstanceMethod(
            WelfareRemoteAppDelegateSwizzler.self,
            swizzledSelector
        )

        guard let swizzledImp = swizzledImp else {
            print("[WelfareRemote] ⚠️ swizzled 方法未找到")
            return
        }

        // 交换实现
        method_exchangeImplementations(originalMethod, swizzledImp)
        print("[WelfareRemote] ✅ didFinishLaunching swizzle 安装完成")
    }

    @MainActor
    @objc func swizzled_didFinishLaunching(
        _ application: UIApplication,
        launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // 调用原实现（已 swizzled，self.swizzled_xxx 实际指向原 original）
        let result = self.swizzled_didFinishLaunching(application, launchOptions: launchOptions)

        // 兜底激活：再次调用 bootstrap（幂等）
        WelfarePlatformConfigStore.shared.bootstrap()

        return result
    }
}
