import SwiftUI

// MARK: - 更新弹窗
struct UpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var isPresented: Bool
    @StateObject private var updateManager = UpdateManager.shared

    init(isPresented: Binding<Bool>? = nil) {
        self._isPresented = isPresented ?? .constant(true)
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// 把 Release body 解析成更新条目列表
    private var notes: [String] {
        updateManager.releaseNotes
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("##") && !$0.hasPrefix("---") }
            .map { line in
                // 去掉行首的 "1、" / "1." / "1．" 等序号前缀
                let pattern = #"^\d+[、.．]\s*"#
                if let range = line.range(of: pattern, options: .regularExpression) {
                    return String(line[range.upperBound...])
                }
                // 去掉 markdown 列表前缀 "- " 或 "* "
                if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
                if line.hasPrefix("* ") { return String(line.dropFirst(2)) }
                return line
            }
    }

    private func close() {
        // 如果正在下载，先取消
        if updateManager.isDownloading {
            updateManager.cancelDownload()
        }
        dismiss()
        isPresented = false
    }

    private func minimize() {
        withAnimation(.easeInOut(duration: 0.3)) {
            updateManager.isMinimized = true
        }
        dismiss()
        isPresented = false
    }

    /// 按钮文案与状态
    private var buttonTitle: String {
        if updateManager.isDownloading {
            return "取消下载"
        }
        if updateManager.downloadError != nil {
            return "重新下载"
        }
        if updateManager.downloadedIPAPath != nil {
            return updateManager.hasTrollStore ? "安装更新" : "分享安装包"
        }
        return "马上升级"
    }

    /// 按钮动作
    private func handleButtonAction() {
        if updateManager.isDownloading {
            // 下载中点击则取消
            updateManager.cancelDownload()
            return
        }

        if updateManager.downloadedIPAPath != nil {
            // 已下载，执行安装
            updateManager.installIPA()
            // 延迟关闭弹窗（让用户看到安装动作）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                close()
            }
            return
        }

        // 开始下载
        Task {
            await updateManager.downloadIPA()
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                // 顶部关闭按钮（下载中追加缩小按钮）
                HStack {
                    // 下载中显示缩小按钮
                    if updateManager.isDownloading {
                        Button(action: minimize) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.gray)
                                .frame(width: 24, height: 24)
                                .background(Color.gray.opacity(0.12))
                                .clipShape(Circle())
                        }
                    }
                    Spacer()
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.gray)
                        .frame(width: 24, height: 24)
                        .background(Color.gray.opacity(0.12))
                        .clipShape(Circle())
                        .onTapGesture { close() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // 图标（下载中显示旋转动画）
                if updateManager.isDownloading {
                    Image(systemName: "arrow.down.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 70, height: 70)
                        .foregroundColor(Color(hex: "00A8FF"))
                } else if updateManager.downloadedIPAPath != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 70, height: 70)
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "paperplane.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 70, height: 70)
                        .foregroundColor(Color(hex: "00A8FF"))
                        .rotationEffect(.degrees(-30))
                }

                // 标题
                Text(updateManager.isDownloading ? "正在下载" : (updateManager.downloadedIPAPath != nil ? "下载完成" : "发现新版本"))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.primary)
                    .padding(.top, 4)

                // 最新版本号
                Text(updateManager.latestVersion)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.primary)
                    .padding(.top, 2)

                // 下载进度条（下载中显示）
                if updateManager.isDownloading {
                    VStack(spacing: 6) {
                        ProgressView(value: updateManager.downloadProgress)
                            .progressViewStyle(.linear)
                            .tint(Color(hex: "00A8FF"))
                            .padding(.horizontal, 40)
                            .padding(.top, 16)

                        HStack {
                            Text("\(Int(updateManager.downloadProgress * 100))%")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("点击取消")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 40)
                    }
                }

                // 下载错误提示
                if let error = updateManager.downloadError {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .padding(.horizontal, 40)
                        .padding(.top, 12)
                }

                // TrollStore 状态提示
                if updateManager.downloadedIPAPath != nil && !updateManager.hasTrollStore {
                    Text("未检测到 TrollStore，将弹出分享面板\n请选择 AltStore / SideStore / 存储到文件")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 12)
                }

                // 更新内容（非下载中才显示，节省空间）
                if !updateManager.isDownloading && !notes.isEmpty {
                    ScrollView(showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("\(index + 1)、")
                                        .font(.system(size: 15))
                                        .foregroundColor(.primary)
                                    Text(note)
                                        .font(.system(size: 15))
                                        .foregroundColor(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                    .frame(height: min(CGFloat(notes.count * 30) + 24, 180))
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }

                Spacer(minLength: 16)

                // 操作按钮
                Button(action: handleButtonAction) {
                    HStack {
                        Text(buttonTitle)
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        updateManager.isDownloading ?
                        Color.red.opacity(0.8) :
                        Color(hex: "00A8FF")
                    )
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)

                // 降级入口：Safari 下载
                if !updateManager.isDownloading {
                    Button(action: {
                        updateManager.openReleasePageInSafari()
                        close()
                    }) {
                        Text("用 Safari 下载")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .underline()
                    }
                    .padding(.bottom, 8)
                }

                // 当前版本
                Text("当前版本 \(currentVersion)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.bottom, 20)
            }
            .frame(width: 320, height: updateManager.isDownloading ? 380 : 520)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(uiColor: .systemBackground))
            )
            .animation(.easeInOut(duration: 0.3), value: updateManager.isDownloading)
        }
    }
}

#Preview {
    UpdateSheet()
}

// MARK: - 悬浮下载图标（下载弹窗缩小后显示在屏幕右下角）
struct FloatingDownloadBubble: View {
    @ObservedObject var updateManager = UpdateManager.shared
    var onTap: () -> Void

    @State private var offset: CGSize = .zero
    @State private var isDragging = false

    /// 默认位置：右下角
    private let screenWidth = UIScreen.main.bounds.width
    private let screenHeight = UIScreen.main.bounds.height
    private let bubbleSize: CGFloat = 56

    private var defaultPosition: CGPoint {
        CGPoint(
            x: screenWidth - bubbleSize / 2 - 16,
            y: screenHeight - bubbleSize / 2 - 120
        )
    }

    var body: some View {
        Button(action: {
            // 如果没在拖拽，则触发点击
            if !isDragging {
                onTap()
            }
        }) {
            ZStack {
                // 外圈进度环
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 3)
                    .frame(width: bubbleSize, height: bubbleSize)

                Circle()
                    .trim(from: 0, to: max(0.05, CGFloat(updateManager.downloadProgress)))
                    .stroke(Color(hex: "00A8FF"), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: bubbleSize, height: bubbleSize)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: updateManager.downloadProgress)

                // 内部图标
                Image(systemName: "arrow.down.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 38, height: 38)
                    .foregroundColor(Color(hex: "00A8FF"))
                    .background(
                        Circle()
                            .fill(Color(uiColor: .systemBackground))
                            .frame(width: 38, height: 38)
                    )
                    .clipShape(Circle())
            }
            .frame(width: bubbleSize, height: bubbleSize)
            .background(
                Circle()
                    .fill(Color(uiColor: .systemBackground))
                    .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .position(defaultPosition)
        .offset(offset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    isDragging = true
                    offset = value.translation
                }
                .onEnded { value in
                    isDragging = false
                    // 松手后吸附到最近边缘
                    let newX = defaultPosition.x + value.translation.width
                    let newY = defaultPosition.y + value.translation.height
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        offset = CGSize(
                            width: newX > screenWidth / 2 ? screenWidth - bubbleSize / 2 - 16 - defaultPosition.x : -(defaultPosition.x - bubbleSize / 2 - 16),
                            height: min(max(newY - defaultPosition.y, -(defaultPosition.y - bubbleSize / 2 - 60)), screenHeight - bubbleSize / 2 - 60 - defaultPosition.y)
                        )
                    }
                }
        )
        .transition(.scale.combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: offset)
    }
}
