//
//  RemoteWelfareEntryPoint.swift
//  vbox
//
//  Phase 2：iOS 客户端新增文件（不改任何现有代码）
//  作用：提供一组"开箱即用"的辅助 View/函数，让现有 ProfileView / ContentView 接入远程源只需
//        极少改动（甚至零改动）。所有接入逻辑都集中在这里。
//
// 核心 API：
//        1. RemoteWelfareGateView  →  福利专区入口路由（自动根据开关选择 WelfareHomeView 或 RemoteWelfareHomeView）
//        2. RemoteWelfareSettingsGateView  →  设置页路由
//        3. RemoteWelfarePasswordGateSheet  →  密码弹窗路由
//        4. 监听 .remoteWelfareShouldEnter 通知
//
// 现有代码接入示例（推荐改 3 处，每处 1-2 行）：
//
//  ProfileView.swift 中福利专区按钮：
//     .fullScreenCover(isPresented: $showWelfareSheet) {
//         RemoteWelfareGateView(isPresented: $showWelfareSheet)
//             .environmentObject(settings)
//     }
//
//  ProfileView.swift 中"福利平台设置"按钮：
//     NavigationLink {
//         RemoteWelfareSettingsGateView()
//     } label: { ... }
//
//  ContentView.swift 启动时 bootstrap：
//     .onAppear { WelfarePlatformConfigStore.shared.bootstrap() }
//
// 也可以完全不动现有代码，仅在 ContentView onAppear 调一次 bootstrap()。
// 监听 .remoteWelfareShouldEnter 通知的用户会自己处理跳转。
//

import SwiftUI

// MARK: - 入口路由

/// 福利专区入口路由
/// - 自动根据 WelfarePlatformConfigStore.shared.switchEnabled 选择：
///     - 开启：展示 RemoteWelfarePasswordSheet → RemoteWelfareHomeView
///     - 关闭：直接展示 WelfareHomeView（与之前完全一致）
struct RemoteWelfareGateView: View {
    @Binding var isPresented: Bool
    @State private var showPassword: Bool = true
    @State private var showHome: Bool = false

    var body: some View {
        ZStack {
            if WelfarePlatformConfigStore.shared.switchEnabled {
                if showPassword {
                    RemoteWelfarePasswordSheet(isPresented: $showPassword)
                        .onChange(of: showPassword) { newValue in
                            if !newValue { showHome = true }
                        }
                } else if showHome {
                    RemoteWelfareHomeView()
                        .onAppear {
                            // 监听进入通知（密码弹窗也可能发通知）
                        }
                }
            } else {
                // 关闭开关：使用旧版（与之前完全一致，不影响任何现有功能）
                WelfareHomeView()
                    .onAppear {
                        // 监听 .remoteWelfareShouldEnter 通知（虽然开关关闭，但保留通知兼容）
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteWelfareShouldEnter)) { _ in
            // 收到"进入福利专区"通知时，关闭弹窗，由调用方处理跳转
            if WelfarePlatformConfigStore.shared.switchEnabled {
                isPresented = false
            }
        }
    }
}

// MARK: - 设置页路由

/// 福利平台设置页入口路由
/// - 自动根据开关选择 RemoteWelfareSettingsView 或 WelfareSettingsView
struct RemoteWelfareSettingsGateView: View {
    var body: some View {
        if WelfarePlatformConfigStore.shared.switchEnabled {
            RemoteWelfareSettingsView()
        } else {
            WelfareSettingsView()
        }
    }
}

// MARK: - 密码弹窗路由

/// 密码弹窗入口路由
/// - 自动根据开关选择 RemoteWelfarePasswordSheet 或沿用现有流程
struct RemoteWelfarePasswordGateSheet: View {
    @Binding var isPresented: Bool
    @State private var inner: Bool = true

    var body: some View {
        Group {
            if WelfarePlatformConfigStore.shared.switchEnabled {
                RemoteWelfarePasswordSheet(isPresented: $inner)
                    .onChange(of: inner) { newValue in
                        if !newValue { isPresented = false }
                    }
            } else {
                // 关闭：调用方应继续使用 ProfileView 中的旧弹窗（这里仅占位）
                EmptyView()
            }
        }
    }
}

// MARK: - 启动辅助

/// 福利远程源启动辅助
/// 在 ContentView.onAppear 中调用：
///     WelfareRemoteBootstrapper.bootstrap()
struct WelfareRemoteBootstrapper {
    /// 幂等的 bootstrap 调用
    @MainActor
    static func bootstrap() {
        WelfarePlatformConfigStore.shared.bootstrap()
    }

    /// 手动触发一次远程源拉取
    @MainActor
    static func refresh(completion: ((Result<Int, Error>) -> Void)? = nil) {
        WelfarePlatformConfigStore.shared.refresh(completion: completion)
    }
}
