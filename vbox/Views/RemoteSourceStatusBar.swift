import SwiftUI

/// 远程源加载状态胶囊通知 — 悬浮在底栏上方居中显示，文字超长自动滚动
struct RemoteSourceStatusBar: View {
    @StateObject private var remoteSourceManager = RemoteSourceConfigManager.shared
    @State private var isVisible: Bool = false
    @State private var autoDismissTask: Task<Void, Never>?

    private var statusInfo: (icon: String, message: String, color: Color, bgColor: Color, borderColor: Color) {
        switch remoteSourceManager.loadState {
        case .idle:
            return ("antenna.radiowaves.left.and.right", "远程源待同步", .gray.opacity(0.8), Color.gray.opacity(0.12), Color.gray.opacity(0.2))
        case .loading:
            return ("arrow.triangle.2.circlepath", "远程源同步中...", .white, Color.blue.opacity(0.75), Color.blue.opacity(0.85))
        case .loadedRemote(let version):
            return ("checkmark.icloud.fill", "远程源已更新 v\(version)", .green.opacity(0.9), Color.green.opacity(0.12), Color.green.opacity(0.25))
        case .loadedCache(let version):
            return ("tray.and.arrow.down.fill", "远程源失败，已用缓存 v\(version)", .orange.opacity(0.9), Color.orange.opacity(0.12), Color.orange.opacity(0.25))
        case .failed(let message):
            return ("exclamationmark.triangle.fill", "远程源失败：\(message)", .red.opacity(0.9), Color.red.opacity(0.12), Color.red.opacity(0.25))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isVisible {
                HStack(spacing: 6) {
                    Image(systemName: statusInfo.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(statusInfo.color)

                    MarqueeText(text: statusInfo.message,
                                font: .systemFont(ofSize: 12, weight: .medium),
                                color: statusInfo.color,
                                maxWidth: 200)
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
                .clipShape(Capsule())
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
        case .idle:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isVisible = false }
        case .loading:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isVisible = true }
            scheduleAutoDismiss(after: 15.0)
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

// MARK: - 跑马灯文字组件
private struct MarqueeText: View {
    let text: String
    let font: UIFont
    let color: Color
    let maxWidth: CGFloat

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var animTask: Task<Void, Never>?

    private var needsScroll: Bool { textWidth > maxWidth }

    var body: some View {
        Text(text)
            .font(Font(font))
            .foregroundColor(color)
            .lineLimit(1)
            .fixedSize()
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        textWidth = geo.size.width
                    }
                    Color.clear.onChange(of: text) { _ in
                        textWidth = geo.size.width
                    }
                }
            )
            .offset(x: needsScroll ? offset : 0)
            .mask(alignment: .leading) {
                if needsScroll {
                    Rectangle().frame(width: maxWidth)
                }
            }
            .onChange(of: text) { _ in
                restartAnimation()
            }
            .onAppear {
                restartAnimation()
            }
            .onDisappear {
                animTask?.cancel()
            }
    }

    private func restartAnimation() {
        animTask?.cancel()
        offset = 0

        guard needsScroll else { return }

        animTask = Task {
            // 初始停留
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }

            // 循环滚动
            while !Task.isCancelled {
                let duration = Double(textWidth + maxWidth) / 40.0
                await MainActor.run {
                    withAnimation(.linear(duration: duration)) {
                        offset = -(textWidth + 12)
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    offset = maxWidth
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
            }
        }
    }
}