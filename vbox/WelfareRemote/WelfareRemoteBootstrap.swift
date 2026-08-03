//
//  WelfareRemoteBootstrap.swift
//  vbox
//
//  Phase 2 方案 A：完全不动现有代码 — App 启动自动激活
//  作用：为 WelfarePlatformConfigStore.shared.bootstrap() 提供显式调用入口，
//        实际自动激活由 WelfareRemoteAutoLoader.m 中的 Objective-C +load 完成。
//
//  为什么用 Objective-C +load：
//        Swift 6 已禁止在 Swift 类中定义 class func load()（会被编译器报错）。
//        因此新增一个 Objective-C 文件 WelfareRemoteAutoLoader.m，
//        在类加载时（早于 main）反射调用 WelfareRemoteBootstrapGateway.shared.bootstrap()。
//
//  使用方法（用户操作）：
//        1. 把整个 WelfareRemote/ 目录加到 Xcode target（包含 .m 文件）
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

// MARK: - Objective-C 可见的启动网关

/// 供 WelfareRemoteAutoLoader.m 在 +load 中反射调用的网关类。
/// 该类本身不隔离在 MainActor，内部再调度到 @MainActor 的 Store。
@objc(WelfareRemoteBootstrapGateway)
final class WelfareRemoteBootstrapGateway: NSObject {
    @objc static let shared = WelfareRemoteBootstrapGateway()

    /// 幂等启动 Welfare 远程源
    @objc func bootstrap() {
        Task { @MainActor in
            WelfarePlatformConfigStore.shared.bootstrap()
            print("[WelfareRemote] ✅ Objective-C +load 触发 bootstrap 完成")
        }
    }
}


