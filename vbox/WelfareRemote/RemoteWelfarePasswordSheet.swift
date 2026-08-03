//
//  RemoteWelfarePasswordSheet.swift
//  vbox
//
//  Phase 2：iOS 客户端新增文件（不改任何现有代码）
//  作用：远程源福利专区密码弹窗，与现有 ProfileView 中的 welfareUnlockSheet 并行存在。
//        - 复用 AppSettings.welfarePassword（默认 888888）
//        - 复用 AppSettings.welfareUnlocked 状态
//        - 输入正确密码后才拉取远程源（首次进入时）
//        - 弹窗左上角：刷新按钮，点击立刻拉取最新远程源
//        - 拉取成功/失败：Toast 提示
//
//  使用：
//    if WelfarePlatformConfigStore.shared.switchEnabled {
//        RemoteWelfarePasswordSheet(isPresented: $showSheet)
//    } else {
//        // 走 ProfileView 旧逻辑
//    }
//

import SwiftUI

struct RemoteWelfarePasswordSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var configStore = WelfarePlatformConfigStore.shared

    @State private var passwordInput: String = ""
    @State private var passwordError: Bool = false
    @State private var fetchToast: String?
    @State private var hasUnlocked: Bool = false

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // 头部图标
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.accentColor)
                    .padding(.top, 32)

                Text("福利专区（远程源）")
                    .font(.title2.bold())

                Text("输入正确密码后，将拉取最新的远程福利平台数据")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // 密码输入框
                if !hasUnlocked {
                    SecureField("请输入解锁密码", text: $passwordInput)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 32)
                        .onSubmit { verifyPassword() }
                }

                if passwordError {
                    Text("密码错误，请重新输入")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }

                // 解锁按钮 / 进入按钮
                if !hasUnlocked {
                    Button(action: verifyPassword) {
                        Text("解锁并加载远程源")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.accentColor)
                            )
                    }
                    .padding(.horizontal, 32)
                } else {
                    VStack(spacing: 12) {
                        // 解锁成功提示
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("密码正确")
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, 32)

                        // 远程源状态
                        statusBlock

                        // 入口按钮
                        Button(action: enterWelfare) {
                            Text("进入福利专区")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.accentColor)
                                )
                        }
                        .padding(.horizontal, 32)
                    }
                }

                Spacer()
            }
            .navigationTitle("福利专区")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // 左上角：刷新按钮
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: refreshRemote) {
                        if case .loading = configStore.loadState {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(!hasUnlocked)  // 未解锁时不允许刷新
                    .accessibilityLabel("刷新远程源")
                }
                // 右上角：关闭
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { isPresented = false }
                }
            }
            .overlay(alignment: .top) {
                if let toast = fetchToast {
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.black.opacity(0.85))
                        )
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .onAppear {
            // 如果用户已经解锁过，直接跳过密码
            if settings.welfareUnlocked {
                hasUnlocked = true
            }
            configStore.bootstrap()
        }
    }

    // MARK: - 远程源状态块

    private var statusBlock: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: statusIconName)
                    .foregroundColor(statusColor)
                Text(statusTitle)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            if let detail = statusDetail {
                HStack {
                    Spacer()
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 32)
    }

    private var statusIconName: String {
        switch configStore.loadState {
        case .idle: return "icloud.slash"
        case .loading: return "icloud.and.arrow.down"
        case .loaded: return "checkmark.icloud.fill"
        case .failed: return "exclamationmark.icloud.fill"
        }
    }

    private var statusColor: Color {
        switch configStore.loadState {
        case .idle: return .secondary
        case .loading: return .blue
        case .loaded: return .green
        case .failed: return .red
        }
    }

    private var statusTitle: String {
        switch configStore.loadState {
        case .idle: return "远程源未加载"
        case .loading: return "正在拉取…"
        case .loaded(let count, _): return "已就绪 · \(count) 个平台"
        case .failed: return "拉取失败"
        }
    }

    private var statusDetail: String? {
        switch configStore.loadState {
        case .loaded(_, let v):
            if let v = v { return "version: \(v)" }
            return configStore.lastSuccessTime.map { "上次成功：\($0.formatted(date: .abbreviated, time: .shortened))" }
        case .failed(let msg):
            return msg
        default:
            return configStore.lastSuccessTime.map { "上次成功：\($0.formatted(date: .abbreviated, time: .shortened))" }
        }
    }

    // MARK: - 交互

    private func verifyPassword() {
        if passwordInput == settings.welfarePassword {
            passwordError = false
            hasUnlocked = true
            settings.welfareUnlocked = true
            settings.welfareEnabled = true
            // 密码正确后触发一次远程源拉取
            refreshRemote()
        } else {
            passwordError = true
        }
    }

    private func refreshRemote() {
        configStore.refresh { result in
            switch result {
            case .success(let count):
                showToast("已拉取：\(count) 个平台")
            case .failure(let err):
                showToast("拉取失败：\(err.localizedDescription)")
            }
        }
    }

    private func enterWelfare() {
        // 关闭密码弹窗，调用方根据配置跳转到 RemoteWelfareHomeView
        isPresented = false
        // 通知调用方跳转（通过 NotificationCenter）
        NotificationCenter.default.post(
            name: .remoteWelfareShouldEnter,
            object: nil
        )
    }

    private func showToast(_ text: String) {
        withAnimation { fetchToast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { fetchToast = nil }
        }
    }
}

// MARK: - 通知

extension Notification.Name {
    /// 远程源密码弹窗点击「进入福利专区」时发出的通知
    /// 调用方监听后跳转到 RemoteWelfareHomeView
    static let remoteWelfareShouldEnter = Notification.Name("remoteWelfareShouldEnter")
}
