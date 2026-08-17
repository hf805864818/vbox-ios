import SwiftUI
import UIKit
import AVKit
import Photos
import UniformTypeIdentifiers

// MARK: - 胶囊通知消息模型

struct DownloadCapsuleMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let icon: String
    let type: CapsuleType

    enum CapsuleType {
        case info       // 正在下载
        case success    // 下载完成
        case failure    // 下载失败
        case network    // 网络失败
    }

    var color: Color {
        switch type {
        case .info: return .blue
        case .success: return .green
        case .failure: return .red
        case .network: return .orange
        }
    }
}

// MARK: - 胶囊通知视图

struct DownloadCapsuleView: View {
    let message: DownloadCapsuleMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: message.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(message.color)

            Text(message.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.82))
                .overlay(
                    Capsule()
                        .stroke(message.color.opacity(0.4), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
    }
}

// MARK: - 悬浮下载按键

struct FloatingVideoDownloadButton: View {
    @ObservedObject var downloadManager = DownloadManager.shared
    var onTap: () -> Void

    @State private var offset: CGSize = .zero
    @State private var isDragging = false
    @State private var hasMoved = false

    private let screenWidth = UIScreen.main.bounds.width
    private let screenHeight = UIScreen.main.bounds.height
    private let buttonSize: CGFloat = 48

    private var defaultPosition: CGPoint {
        CGPoint(
            x: screenWidth - buttonSize / 2 - 16,
            y: screenHeight - buttonSize / 2 - 140
        )
    }

    /// 整体下载进度（所有活跃任务的平均值）
    private var overallProgress: Double {
        let active = downloadManager.activeDownloads.filter {
            $0.status == "downloading" || $0.status == "pending"
        }
        guard !active.isEmpty else { return 0 }
        let total = active.reduce(0.0) { $0 + $1.progress }
        return total / Double(active.count)
    }

    private var hasActiveDownloads: Bool {
        downloadManager.activeDownloads.contains {
            $0.status == "downloading" || $0.status == "pending"
        }
    }

    private var hasAnyDownloads: Bool {
        !downloadManager.activeDownloads.isEmpty
    }

    var body: some View {
        if hasAnyDownloads {
            Button(action: {
                if !hasMoved {
                    onTap()
                }
                hasMoved = false
            }) {
                bubbleContent
            }
            .buttonStyle(PlainButtonStyle())
            .position(defaultPosition)
            .offset(offset)
            .gesture(dragGesture)
            .transition(.scale.combined(with: .opacity))
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: offset)
        }
    }

    private var bubbleContent: some View {
        ZStack {
            // 进度环
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: 3)
                .frame(width: buttonSize, height: buttonSize)

            if hasActiveDownloads {
                Circle()
                    .trim(from: 0, to: max(0.05, CGFloat(overallProgress)))
                    .stroke(Color(hex: "00A8FF"), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: buttonSize, height: buttonSize)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.3), value: overallProgress)
            }

            // 中心图标
            Image(systemName: hasActiveDownloads ? "arrow.down.circle.fill" : "tray.full.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
                .foregroundColor(hasActiveDownloads ? Color(hex: "00A8FF") : Color(hex: "22C55E"))
                .background(
                    Circle()
                        .fill(Color(uiColor: .systemBackground))
                        .frame(width: 28, height: 28)
                )
                .clipShape(Circle())

            // 下载中数量角标
            if hasActiveDownloads {
                let activeCount = downloadManager.activeDownloads.filter {
                    $0.status == "downloading" || $0.status == "pending"
                }.count
                Text("\(activeCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.red))
                    .offset(x: buttonSize / 2 - 4, y: -buttonSize / 2 + 4)
            }
        }
        .frame(width: buttonSize, height: buttonSize)
        .background(
            Circle()
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 3)
        )
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                isDragging = true
                offset = value.translation
                if abs(value.translation.width) > 5 || abs(value.translation.height) > 5 {
                    hasMoved = true
                }
            }
            .onEnded { value in
                isDragging = false
                let newX = defaultPosition.x + value.translation.width
                let newY = defaultPosition.y + value.translation.height

                // 吸附到最近的边缘
                let snapX: CGFloat = newX > screenWidth / 2
                    ? screenWidth - buttonSize / 2 - 16 - defaultPosition.x
                    : buttonSize / 2 + 16 - defaultPosition.x

                // 限制 Y 轴范围
                let clampedY = max(buttonSize / 2 + 60, min(screenHeight - buttonSize / 2 - 100, newY))
                let snapY = clampedY - defaultPosition.y

                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    offset = CGSize(width: snapX, height: snapY)
                }
            }
    }
}

// MARK: - 下载管理悬浮弹窗

struct DownloadManagementPopup: View {
    @Binding var isPresented: Bool
    @State private var downloadRecords: [DownloadRecord] = []
    @State private var playingRecord: DownloadRecord?
    @State private var showSaveSuccess = false
    @State private var saveSuccessMessage = ""

    var body: some View {
        ZStack {
            // 半透明背景
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isPresented = false
                    }
                }

            // 弹窗主体
            VStack(spacing: 0) {
                // 标题栏
                HStack {
                    Text("下载管理")
                        .font(.system(size: 17, weight: .semibold))
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isPresented = false
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

                if downloadRecords.isEmpty {
                    VStack(spacing: 12) {
                        Spacer().frame(height: 60)
                        Image(systemName: "tray")
                            .font(.system(size: 40))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("暂无下载内容")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            // 下载中
                            let downloading = downloadRecords.filter {
                                $0.status == "downloading" || $0.status == "pending"
                            }
                            if !downloading.isEmpty {
                                downloadSectionHeader("下载中", count: downloading.count, color: .blue)
                                ForEach(downloading) { record in
                                    DownloadPopupProgressRow(record: record)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 8)
                                }
                            }

                            // 已完成
                            let completed = downloadRecords.filter { $0.status == "completed" }
                            if !completed.isEmpty {
                                downloadSectionHeader("已完成", count: completed.count, color: .green)
                                ForEach(completed) { record in
                                    DownloadPopupCompletedRow(
                                        record: record,
                                        onPlay: {
                                            playingRecord = record
                                        },
                                        onSaveToFiles: {
                                            saveToFiles(record: record)
                                        },
                                        onSaveToPhotos: {
                                            saveToPhotos(record: record)
                                        },
                                        onDelete: {
                                            deleteRecord(record)
                                        }
                                    )
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 8)
                                }
                            }

                            // 失败
                            let failed = downloadRecords.filter { $0.status == "failed" }
                            if !failed.isEmpty {
                                downloadSectionHeader("下载失败", count: failed.count, color: .red)
                                ForEach(failed) { record in
                                    DownloadPopupFailedRow(
                                        record: record,
                                        onRetry: {
                                            DownloadManager.shared.retryDownload(id: record.id ?? 0)
                                            reloadDownloads()
                                        },
                                        onDelete: {
                                            deleteRecord(record)
                                        }
                                    )
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 8)
                                }
                            }
                        }
                        .padding(.bottom, 20)
                    }
                }

                // 底部操作栏
                if !downloadRecords.isEmpty {
                    Divider()
                    HStack {
                        Button("清空已完成") {
                            DownloadManager.shared.clearCompleted()
                            reloadDownloads()
                        }
                        .font(.system(size: 13))
                        .foregroundColor(.red)

                        Spacer()

                        Button("清空全部") {
                            DatabaseManager.shared.clearDownloads()
                            reloadDownloads()
                        }
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(uiColor: .systemBackground))
                    .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
            )
            .frame(maxHeight: UIScreen.main.bounds.height * 0.7)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .onAppear {
            reloadDownloads()
        }
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            if downloadRecords.contains(where: { $0.status == "downloading" || $0.status == "pending" }) {
                reloadDownloads()
            }
        }
        .fullScreenCover(item: $playingRecord) { record in
            LocalVideoPlayerView(filePath: record.filePath, title: record.name)
        }
        .overlay {
            if showSaveSuccess {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(saveSuccessMessage)
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .padding(.bottom, 30)
                }
                .transition(.opacity)
                .animation(.easeInOut, value: showSaveSuccess)
            }
        }
    }

    private func downloadSectionHeader(_ title: String, count: Int, color: Color) -> some View {
        HStack {
            Text("\(title) (\(count))")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func reloadDownloads() {
        downloadRecords = DatabaseManager.shared.queryDownloads()
    }

    private func deleteRecord(_ record: DownloadRecord) {
        if !record.filePath.isEmpty {
            try? FileManager.default.removeItem(atPath: record.filePath)
        }
        DatabaseManager.shared.deleteDownload(id: record.id ?? 0)
        reloadDownloads()
    }

    // MARK: - 保存到文件 App

    private func saveToFiles(record: DownloadRecord) {
        guard !record.filePath.isEmpty,
              FileManager.default.fileExists(atPath: record.filePath) else {
            showSaveMessage("文件不存在，无法保存")
            return
        }

        let fileURL = URL(fileURLWithPath: record.filePath)
        let documentPicker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        documentPicker.shouldShowFileExtensions = true

        // 获取当前最顶层的 ViewController 来 present
        if let topVC = topMostViewController() {
            topVC.present(documentPicker, animated: true)
        }
    }

    // MARK: - 保存到相册

    private func saveToPhotos(record: DownloadRecord) {
        guard !record.filePath.isEmpty,
              FileManager.default.fileExists(atPath: record.filePath) else {
            showSaveMessage("文件不存在，无法保存")
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .authorized || status == .limited {
            performSaveToPhotos(record: record)
        } else {
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                DispatchQueue.main.async {
                    if newStatus == .authorized || newStatus == .limited {
                        performSaveToPhotos(record: record)
                    } else {
                        showSaveMessage("相册权限被拒绝，无法保存")
                    }
                }
            }
        }
    }

    private func performSaveToPhotos(record: DownloadRecord) {
        let videoPath = record.filePath
        let ext = (videoPath as NSString).pathExtension.lowercased()

        if ext == "mp4" || ext == "mov" || ext == "m4v" {
            UISaveVideoAtPathToSavedPhotosAlbum(videoPath, nil, nil, nil)
            showSaveMessage("已保存到相册")
        } else {
            // TS 等格式需要先转 MP4
            convertAndSaveToPhotos(filePath: videoPath, name: record.name)
        }
    }

    private func convertAndSaveToPhotos(filePath: String, name: String) {
        let asset = AVAsset(url: URL(fileURLWithPath: filePath))
        guard asset.tracks(withMediaType: .video).first != nil else {
            // 纯音频或无法转换，保存到文件 App
            showSaveMessage("该格式不支持保存到相册，请使用保存到文件")
            return
        }

        let preset = AVAssetExportPresetHighestQuality
        guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
            showSaveMessage("视频转换失败")
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbox_export_\(UUID().uuidString).mp4")
        exporter.outputURL = tempURL
        exporter.outputFileType = .mp4

        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                switch exporter.status {
                case .completed:
                    UISaveVideoAtPathToSavedPhotosAlbum(tempURL.path, nil, nil, nil)
                    try? FileManager.default.removeItem(at: tempURL)
                    showSaveMessage("已转换并保存到相册")
                default:
                    showSaveMessage("视频转换失败")
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }
        }
    }

    private func showSaveMessage(_ message: String) {
        saveSuccessMessage = message
        withAnimation(.easeInOut(duration: 0.25)) {
            showSaveSuccess = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeInOut(duration: 0.25)) {
                showSaveSuccess = false
            }
        }
    }

    // 获取最顶层 ViewController
    private func topMostViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              let rootVC = window.rootViewController else {
            return nil
        }
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        return topVC
    }
}

// MARK: - 下载弹窗行视图

private struct DownloadPopupProgressRow: View {
    let record: DownloadRecord

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.laiyuan)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                    if let st = record.sourceType, !st.isEmpty {
                        Text(st == "cloud" ? "网盘" : "普通")
                            .font(.system(size: 10))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
                if record.status == "downloading" {
                    ProgressView(value: record.progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                        .frame(height: 3)
                    HStack(spacing: 4) {
                        Text("\(Int(record.progress * 100))%")
                        if record.downloadedSize > 0 {
                            Text("· \(formatBytes(record.downloadedSize))")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.blue)
                } else {
                    Text("等待下载")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                }
            }
            Spacer()
        }
    }
}

private struct DownloadPopupCompletedRow: View {
    let record: DownloadRecord
    let onPlay: () -> Void
    let onSaveToFiles: () -> Void
    let onSaveToPhotos: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // 播放按钮
            Button(action: onPlay) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.laiyuan)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                    if record.fileSize > 0 {
                        Text("· \(formatBytes(record.fileSize))")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                    }
                }
            }
            Spacer()

            // 操作菜单
            Menu {
                Button(action: onPlay) {
                    Label("播放", systemImage: "play.fill")
                }
                Button(action: onSaveToFiles) {
                    Label("保存到文件", systemImage: "folder.badge.plus")
                }
                Button(action: onSaveToPhotos) {
                    Label("保存到相册", systemImage: "photo.badge.arrow.down")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct DownloadPopupFailedRow: View {
    let record: DownloadRecord
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("下载失败")
                    .font(.system(size: 10))
                    .foregroundColor(.red)
            }
            Spacer()

            Button(action: onRetry) {
                Image(systemName: "arrow.clockwise.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 本地视频播放器

struct LocalVideoPlayerView: View {
    let filePath: String
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部栏
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)

                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)

                // 视频播放区域
                if FileManager.default.fileExists(atPath: filePath) {
                    LocalAVPlayer(filePath: filePath)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("视频文件不存在")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                        Text("文件可能已被删除或移动")
                            .font(.system(size: 12))
                            .foregroundColor(.gray.opacity(0.7))
                    }
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }
}

private struct LocalAVPlayer: UIViewControllerRepresentable {
    let filePath: String

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        let url = URL(fileURLWithPath: filePath)
        let player = AVPlayer(url: url)
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.showsPlaybackControls = true
        controller.videoGravity = .resizeAspect
        player.play()
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

// MARK: - DownloadRecord Identifiable 扩展（用于 fullScreenCover）

extension DownloadRecord {
    // DownloadRecord 已实现 Identifiable（id: Int?）
    // 但 fullScreenCover 需要 Identifiable 且 id 非 optional
    // 通过 wrapper 解决
}

// MARK: - 辅助函数

private func formatBytes(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
    if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
    return String(format: "%.1f GB", Double(bytes) / (1024 * 1024 * 1024))
}
