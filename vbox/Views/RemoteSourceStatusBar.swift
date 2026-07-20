import SwiftUI

/// 远程源加载状态通知横条 — 显示在首页底栏上方
struct RemoteSourceStatusBar: View {
    @StateObject private var remoteSourceManager = RemoteSourceConfigManager.shared
    @State private var isVisible: Bool = false
    @State private var autoDismissTask: Task<Void, Never>?

    private var statusInfo: (icon: String, message: String, color: Color, bgColor: Color) {
        switch remoteSourceManager.loadState {
        case .idle:
            return ("antenna.radiowaves.left.and.right", "远程源待同步", .gray, Color.gray.opacity(0.12))
        case .loading:
            return ("arrow.triangle.2.circlepath", "远程源同步中...", .blue, Color.blue.opacity(0.12))
        case .loadedRemote(let version):
            return ("checkmark.icloud.fill", "远程源加载成功 (v\(version))", .green, Color.green.opacity(0.12))
        case .loadedCache(let version):
            return ("tray.and.arrow.down.fill", "远程源失败，已降级到缓存 (v\(version))", .orange, Color.orange.opacity(0.12))
        case .failed(let message):
            return ("exclamationmark.triangle.fill", "远程源加载失败：\(message)", .red, Color.red.opacity(0.12))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isVisible {
                HStack(spacing: 8) {
                    Image(systemName: statusInfo.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(statusInfo.color)

                    Text(statusInfo.message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(statusInfo.color)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isVisible = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(statusInfo.color.opacity(0.6))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(statusInfo.bgColor)
                .overlay(
                    Rectangle()
                        .frame(height: 2)
                        .foregroundColor(statusInfo.color.opacity(0.4)),
                    alignment: .top
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: remoteSourceManager.loadState) { newState in
            handleStateChange(newState)
        }
        .onAppear {
            if case .idle = remoteSourceManager.loadState { } else { handleStateChange(remoteSourceManager.loadState) }
        }
    }

    private func handleStateChange(_ state: RemoteSourceConfigManager.LoadState) {
        autoDismissTask?.cancel()

        switch state {
        case .idle, .loading:
            withAnimation(.easeInOut(duration: 0.25)) { isVisible = false }
        case .loadedRemote, .loadedCache:
            withAnimation(.easeInOut(duration: 0.25)) { isVisible = true }
            scheduleAutoDismiss(after: 3.0)
        case .failed:
            withAnimation(.easeInOut(duration: 0.25)) { isVisible = true }
            scheduleAutoDismiss(after: 6.0)
        }
    }

    private func scheduleAutoDismiss(after seconds: TimeInterval) {
        autoDismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) {
                    isVisible = false
                }
            }
        }
    }
}