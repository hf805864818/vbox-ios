import SwiftUI

/// 远程源加载状态胶囊通知 — 悬浮在底栏上方居中显示
struct RemoteSourceStatusBar: View {
    @StateObject private var remoteSourceManager = RemoteSourceConfigManager.shared
    @State private var isVisible: Bool = false
    @State private var autoDismissTask: Task<Void, Never>?

    private var statusInfo: (icon: String, message: String, color: Color, bgColor: Color, borderColor: Color) {
        switch remoteSourceManager.loadState {
        case .idle:
            return ("antenna.radiowaves.left.and.right", "远程源待同步", .gray.opacity(0.8), Color.gray.opacity(0.12), Color.gray.opacity(0.2))
        case .loading:
            return ("arrow.triangle.2.circlepath", "远程源同步中...", .blue.opacity(0.9), Color.blue.opacity(0.12), Color.blue.opacity(0.25))
        case .loadedRemote(let version):
            return ("checkmark.icloud.fill", "远程源已更新 v\(version)", .green.opacity(0.9), Color.green.opacity(0.12), Color.green.opacity(0.25))
        case .loadedCache(let version):
            return ("tray.and.arrow.down.fill", "远程源失败，已用缓存 v\(version)", .orange.opacity(0.9), Color.orange.opacity(0.12), Color.orange.opacity(0.25))
        case .failed(let message):
            let short = message.count > 20 ? String(message.prefix(20)) + "..." : message
            return ("exclamationmark.triangle.fill", "远程源失败：\(short)", .red.opacity(0.9), Color.red.opacity(0.12), Color.red.opacity(0.25))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isVisible {
                HStack(spacing: 6) {
                    Image(systemName: statusInfo.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(statusInfo.color)

                    Text(statusInfo.message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(statusInfo.color)
                        .lineLimit(1)

                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            isVisible = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(statusInfo.color.opacity(0.5))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(statusInfo.bgColor)
                )
                .overlay(
                    Capsule()
                        .stroke(statusInfo.borderColor, lineWidth: 0.5)
                )
                .padding(.bottom, 6)
                .shadow(color: Color.black.opacity(0.08), radius: 6, y: 2)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9)),
                    removal: .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.9))
                ))
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: remoteSourceManager.loadState) { newState in
            handleStateChange(newState)
        }
        .onAppear {
            if case .idle = remoteSourceManager.loadState { } else {
                handleStateChange(remoteSourceManager.loadState)
            }
        }
    }

    private func handleStateChange(_ state: RemoteSourceConfigManager.LoadState) {
        autoDismissTask?.cancel()

        switch state {
        case .idle, .loading:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isVisible = false }
        case .loadedRemote, .loadedCache:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isVisible = true }
            scheduleAutoDismiss(after: 4.0)
        case .failed:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isVisible = true }
            scheduleAutoDismiss(after: 8.0)
        }
    }

    private func scheduleAutoDismiss(after seconds: TimeInterval) {
        autoDismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    isVisible = false
                }
            }
        }
    }
}