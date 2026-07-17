import Foundation
import SwiftUI
import UIKit

/// 自动更新管理器 — 检查GitHub Releases版本更新，支持APP内下载安装
@MainActor
class UpdateManager: ObservableObject {

    static let shared = UpdateManager()

    // MARK: - 检查更新状态
    @Published var isChecking = false
    @Published var hasUpdate = false
    @Published var latestVersion = ""
    @Published var latestBuild = ""
    @Published var downloadURL: String?
    @Published var releasePageURL: String?
    @Published var releaseNotes = ""
    @Published var updateError: String?

    // MARK: - 下载安装状态
    /// 下载进度 0.0 ~ 1.0
    @Published var downloadProgress: Double = 0
    /// 是否正在下载
    @Published var isDownloading = false
    /// 下载完成后的本地 IPA 文件路径
    @Published var downloadedIPAPath: URL?
    /// 下载错误信息
    @Published var downloadError: String?
    /// 是否安装了 TrollStore
    @Published var hasTrollStore = false
    /// 下载弹窗是否已缩小为悬浮图标
    @Published var isMinimized = false

    // B 仓库配置 — APP 从这里检查更新和下载 IPA
    private let repoOwner = "hfkj520"
    private let repoName = "vbox-release"

    /// 下载任务
    private var downloadTask: Task<Void, Never>?
    /// 上次检查更新的时间戳（5分钟内不重复检查）
    private var lastCheckTime: Date?
    private let checkInterval: TimeInterval = 300 // 5分钟

    private var currentVersion: String {
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3"
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var currentBuild: String {
        let raw = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把 tag/版本字符串清理成纯数字+点，例如 "v3.700-beta" -> "3.700"
    private func cleanVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        var cleaned = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        cleaned = cleaned.components(separatedBy: "-").first ?? cleaned
        cleaned = cleaned.filter { $0.isNumber || $0 == "." }
        return cleaned
    }

    private init() {
        // 启动时检测 TrollStore
        checkTrollStoreAvailability()
    }

    // MARK: - TrollStore 检测

    /// 检测设备是否安装了 TrollStore
    func checkTrollStoreAvailability() {
        // TrollStore 注册的 URL Scheme
        // tsinstall:// 是 TrollStore 安装 scheme
        let trollStoreSchemes = [
            "apple-magnifier://",  // TrollStore 2 常用
            "tsinstall://",        // TrollStore 安装 scheme
        ]

        for scheme in trollStoreSchemes {
            if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
                hasTrollStore = true
                print("[UpdateManager] 检测到 TrollStore")
                return
            }
        }
        hasTrollStore = false
        print("[UpdateManager] 未检测到 TrollStore")
    }

    // MARK: - 检查更新（带缓存，避免频繁请求）

    /// 检查更新（带5分钟缓存）
    func checkForUpdate(force: Bool = false) async {
        // 非强制检查时，5分钟内不重复请求
        if !force, let last = lastCheckTime, Date().timeIntervalSince(last) < checkInterval {
            print("[UpdateManager] 距上次检查不足5分钟，跳过")
            return
        }
        lastCheckTime = Date()

        isChecking = true
        updateError = nil

        do {
            let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases?per_page=1")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

            let (data, _) = try await URLSession.shared.data(for: request)

            if let releases = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let json = releases.first {
                let tagName = json["tag_name"] as? String ?? ""
                let body = json["body"] as? String ?? ""
                let htmlURL = json["html_url"] as? String
                let assets = json["assets"] as? [[String: Any]] ?? []

                var ipaURL: String?
                for asset in assets {
                    if (asset["name"] as? String)?.hasSuffix(".ipa") == true {
                        ipaURL = asset["browser_download_url"] as? String
                        break
                    }
                }

                let remoteVersion = cleanVersion(tagName)
                let localVersion = cleanVersion(currentVersion)

                latestVersion = remoteVersion
                releaseNotes = body
                downloadURL = ipaURL
                releasePageURL = htmlURL

                if localVersion.compare(remoteVersion, options: .numeric) == .orderedAscending {
                    hasUpdate = true
                    print("[UpdateManager] 发现新版本: v\(remoteVersion)，当前: v\(localVersion)")
                } else {
                    hasUpdate = false
                    print("[UpdateManager] 已是最新版: v\(localVersion)，远程: v\(remoteVersion)")
                }
            }
        } catch {
            updateError = "检查更新失败: \(error.localizedDescription)"
            print("[UpdateManager] \(updateError!)")
        }

        isChecking = false
    }

    // MARK: - 下载 IPA

    /// 在 APP 内下载 IPA 安装包
    func downloadIPA() async {
        guard let urlString = downloadURL, let url = URL(string: urlString) else {
            downloadError = "下载链接无效"
            return
        }

        // 取消已有下载
        downloadTask?.cancel()

        downloadTask = Task {
            await performDownload(from: url)
        }
        await downloadTask?.value
    }

    // MARK: - 代理下载（静态代理列表 + 直连兜底）

    /// 静态代理列表：主代理 → 备用代理 → 直连
    private static let proxyHosts: [(name: String, host: String)] = [
        ("ghfast",    "https://ghfast.top"),
        ("gh-proxy",  "https://gh-proxy.com"),
    ]

    /// 构造下载 URL 列表：[主代理, 备用代理, 直连GitHub]
    private func buildDownloadURLs(githubURL: String) -> [URL] {
        var urls: [URL] = []
        for (_, host) in Self.proxyHosts {
            if let proxyURL = URL(string: "\(host)/\(githubURL)") {
                urls.append(proxyURL)
            }
        }
        if let directURL = URL(string: githubURL) {
            urls.append(directURL)
        }
        return urls
    }

    // MARK: - 下载代理（URLSession downloadTask delegate，系统级缓冲下载）
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
        var onProgress: ((Double) -> Void)?
        var onComplete: ((Result<URL, Error>) -> Void)?
        var startTime: Date = Date()
        private var downloadedTempURL: URL?
        private var lastReportedBytes: Int64 = 0
        private var lastReportedTime: Date = Date()

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            onProgress?(progress)

            let now = Date()
            let elapsed = now.timeIntervalSince(lastReportedTime)
            if elapsed >= 1.0 {
                let bytesInInterval = totalBytesWritten - lastReportedBytes
                let speedKB = Double(bytesInInterval) / elapsed / 1024.0
                print("[UpdateManager] 下载进度: \(Int(progress * 100))% 速度: \(String(format: "%.0f", speedKB))KB/s")
                lastReportedBytes = totalBytesWritten
                lastReportedTime = now
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let tempDir = FileManager.default.temporaryDirectory
            let copy = tempDir.appendingPathComponent(UUID().uuidString + ".ipa")
            do {
                try FileManager.default.copyItem(at: location, to: copy)
                downloadedTempURL = copy
            } catch {
                print("[UpdateManager] 临时文件拷贝失败: \(error.localizedDescription)")
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error = error {
                onComplete?(.failure(error))
            } else if let url = downloadedTempURL {
                let elapsed = Date().timeIntervalSince(startTime)
                print("[UpdateManager] 下载完成 耗时: \(String(format: "%.1f", elapsed))s")
                onComplete?(.success(url))
            } else {
                onComplete?(.failure(NSError(domain: "UpdateManager", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "未收到下载文件"])))
            }
        }
    }

    /// 使用系统 downloadTask 下载单个文件（系统级缓冲，非逐字节处理）
    private func downloadFile(from url: URL, to destination: URL) async throws {
        let delegate = DownloadDelegate()
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        delegate.onProgress = { [weak self] progress in
            Task { @MainActor in
                self?.downloadProgress = progress
            }
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let task = session.downloadTask(with: request)

        let tempURL: URL = try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.onComplete = { result in
                        continuation.resume(with: result)
                    }
                    task.resume()
                }
            },
            onCancel: {
                task.cancel()
            }
        )

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// 执行实际下载（主代理 → 备用代理 → 直连兜底）
    private func performDownload(from url: URL) async {
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        downloadedIPAPath = nil

        let tempDir = FileManager.default.temporaryDirectory
        let destinationURL = tempDir.appendingPathComponent("vbox_update.ipa")

        // 删除旧文件
        try? FileManager.default.removeItem(at: destinationURL)

        let downloadURLs = buildDownloadURLs(githubURL: url.absoluteString)
        print("[UpdateManager] 下载地址: \(downloadURLs.count) 个 (主代理 → 备用代理 → 直连兜底)")

        for (idx, downloadURL) in downloadURLs.enumerated() {
            if Task.isCancelled { break }
            let label: String
            switch idx {
            case 0: label = "主代理(ghfast)"
            case 1: label = "备用代理(gh-proxy)"
            default: label = "直连"
            }
            print("[UpdateManager] 下载尝试 #\(idx+1): \(label) \(downloadURL.host ?? "")")

            do {
                try await downloadFile(from: downloadURL, to: destinationURL)
                downloadProgress = 1.0
                downloadedIPAPath = destinationURL
                print("[UpdateManager] IPA 下载完成: \(destinationURL.path)")
                isDownloading = false
                return
            } catch {
                if Task.isCancelled { break }
                print("[UpdateManager] #\(idx+1) 下载失败: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: destinationURL)
            }
        }

        downloadError = "所有下载源均失败，请检查网络"
        isDownloading = false
    }

    /// 取消下载
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        print("[UpdateManager] 用户取消下载")
    }

    // MARK: - 安装 IPA

    /// 安装已下载的 IPA
    /// 优先尝试 TrollStore，没有则弹出系统分享面板
    func installIPA() {
        guard let ipaPath = downloadedIPAPath else {
            print("[UpdateManager] 没有已下载的 IPA 文件")
            return
        }

        // 重新检测 TrollStore
        checkTrollStoreAvailability()

        if hasTrollStore {
            // 方式1: 通过 TrollStore URL Scheme 安装
            installViaTrollStore(ipaPath: ipaPath)
        } else {
            // 方式2: 弹出系统分享面板（AltStore / SideStore / 文件 App）
            shareIPA(ipaPath: ipaPath)
        }
    }

    /// 通过 TrollStore 安装 IPA
    private func installViaTrollStore(ipaPath: URL) {
        // TrollStore 支持的安装方式：
        // 1. tsinstall://url=<编码后的文件URL>
        // 2. apple-magnifier://install?url=<编码后的文件URL>
        let fileURLString = ipaPath.absoluteString
        let encodedURL = fileURLString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileURLString

        // 尝试多种 TrollStore scheme
        let schemes = [
            "tsinstall://install?url=\(encodedURL)",
            "apple-magnifier://install?url=\(encodedURL)",
        ]

        for scheme in schemes {
            if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
                print("[UpdateManager] 通过 TrollStore 安装: \(scheme)")
                UIApplication.shared.open(url)
                return
            }
        }

        // 所有 scheme 都失败，降级到分享面板
        print("[UpdateManager] TrollStore scheme 不可用，降级到分享面板")
        shareIPA(ipaPath: ipaPath)
    }

    /// 通过系统分享面板分享 IPA 文件
    /// 用户可以选择 AltStore / SideStore / 存储到文件等
    private func shareIPA(ipaPath: URL) {
        print("[UpdateManager] 弹出分享面板: \(ipaPath.path)")

        // 获取当前最顶层的 ViewController
        guard let rootVC = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?
            .rootViewController else {
            // 降级：如果无法获取 VC，直接打开 Safari
            openReleasePageInSafari()
            return
        }

        // 找到最顶层的 presented VC
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }

        let activityVC = UIActivityViewController(
            activityItems: [ipaPath],
            applicationActivities: nil
        )

        // iPad 适配
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = topVC.view
            popover.sourceRect = CGRect(
                x: topVC.view.bounds.midX,
                y: topVC.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }

        topVC.present(activityVC, animated: true)
    }

    /// 打开 Release 页面（降级方案，跳转 Safari）
    func openReleasePageInSafari() {
        guard let url = releasePageURL ?? downloadURL, let urlObj = URL(string: url) else { return }
        UIApplication.shared.open(urlObj)
    }
}
