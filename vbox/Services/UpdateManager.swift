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

    // MARK: - 代理节点（页面动态提取 + 硬编码兜底 + 并行GET Range竞速）

    /// 硬编码代理节点兜底列表
    /// 当 github.akams.cn 页面提取失败时使用，国内可直接访问这些 GitHub 加速镜像
    private let fallbackProxyNodes: [String] = [
        "gh-proxy.com",
        "ghproxy.net",
        "mirror.ghproxy.com",
        "gh.dpik.top",
        "github.starrlzy.cn",
        "gh.tryxd.cn",
        "cdn.akaere.online",
        "github-proxy.memory-echoes.cn",
        "gitproxy.127731.xyz",
        "github.tbap.top",
    ]

    /// 获取代理节点：优先页面动态提取，失败用硬编码兜底，并行 GET Range 测速后选最快
    private func fetchAndRankProxyNodes(githubURL: String) async -> [URL] {
        let top8 = await fetchTopProxyNodesFromPage(count: 8)
        print("[UpdateManager] 页面提取到前\(top8.count)个节点: \(top8)")

        // 页面提取失败时，用硬编码节点兜底（国内用户无代理也能访问这些镜像站）
        let candidates = top8.isEmpty ? fallbackProxyNodes : top8
        print("[UpdateManager] 候选代理节点: \(candidates.count) 个")

        // 并行 GET Range 测速（前5个节点同时竞速，取第一个成功的）
        let best = await raceProxyNodes(candidates, githubURL: githubURL)

        if let best {
            print("[UpdateManager] 竞速胜出: \(best.url.host ?? "?") \(String(format: "%.0f", best.ms))ms")
            return [best.url, URL(string: githubURL)!]
        }

        // 全部失败，直连 GitHub（最终兜底）
        print("[UpdateManager] 节点均不可达，直连 GitHub")
        return [URL(string: githubURL)!]
    }

    /// 并行 GET Range 竞速，返回第一个成功的代理节点
    private func raceProxyNodes(_ hosts: [String], githubURL: String) async -> (url: URL, ms: Double)? {
        await withTaskGroup(of: (url: URL, ms: Double)?.self) { group in
            let maxConcurrent = min(5, hosts.count)
            for (idx, host) in hosts.prefix(maxConcurrent).enumerated() {
                let proxyURL = URL(string: "https://\(host)/\(githubURL)")!
                group.addTask {
                    var req = URLRequest(url: proxyURL)
                    req.httpMethod = "GET"
                    req.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
                    req.timeoutInterval = 4.0
                    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                    let start = Date()
                    do {
                        let (data, resp) = try await URLSession.shared.data(for: req)
                        let ms = Date().timeIntervalSince(start) * 1000
                        if let http = resp as? HTTPURLResponse,
                           (http.statusCode == 200 || http.statusCode == 206),
                           !data.isEmpty {
                            print("[UpdateManager]   #\(idx+1) \(host) \(String(format: "%.0f", ms))ms ✅")
                            return (proxyURL, ms)
                        } else {
                            print("[UpdateManager]   #\(idx+1) \(host) HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
                            return nil
                        }
                    } catch {
                        print("[UpdateManager]   #\(idx+1) \(host) 不可达: \(error.localizedDescription)")
                        return nil
                    }
                }
            }

            // 第一个成功的返回
            for await result in group {
                if let result { return result }
            }
            return nil
        }
    }

    /// 从 github.akams.cn 页面提取排名前 N 的代理域名（页面已按速度排序）
    private func fetchTopProxyNodesFromPage(count: Int) async -> [String] {
        do {
            var req = URLRequest(url: URL(string: "https://github.akams.cn")!)
            req.timeoutInterval = 8
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let html = String(data: data, encoding: .utf8) else { return [] }

            // 页面格式: [标签]域名延迟值 单位-  (如 [贡献]github.starrlzy.cn388 ms-)
            // 匹配: ] 空白 域名(含数字开头, 如 777.z321.cc.cd) 紧跟数字(延迟)
            let pattern = #"\]\s*([a-zA-Z0-9][-a-zA-Z0-9]*(?:\.[a-zA-Z0-9][-a-zA-Z0-9]*)+(?:\.[a-zA-Z]{2,}))\d"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))

            var seen = Set<String>()
            var domains: [String] = []
            for m in matches {
                guard let r = Range(m.range(at: 1), in: html) else { continue }
                let domain = String(html[r]).lowercased()
                guard !domain.contains("akams.cn") && !domain.contains("github.com")
                      && !domain.hasPrefix("www.") else { continue }
                if seen.insert(domain).inserted {
                    domains.append(domain)
                    if domains.count >= count { break }
                }
            }

            print("[UpdateManager] 正则匹配到 \(domains.count) 个节点")
            return domains
        } catch {
            print("[UpdateManager] 页面获取失败: \(error.localizedDescription)")
        }
        return []
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

    /// 执行实际下载（遍历代理节点 + 直连兜底）
    private func performDownload(from url: URL) async {
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        downloadedIPAPath = nil

        let tempDir = FileManager.default.temporaryDirectory
        let destinationURL = tempDir.appendingPathComponent("vbox_update.ipa")

        // 删除旧文件
        try? FileManager.default.removeItem(at: destinationURL)

        // 动态获取节点 + 本地测速排序
        let proxyURLs = await fetchAndRankProxyNodes(githubURL: url.absoluteString)
        print("[UpdateManager] 下载地址: \(proxyURLs.count) 个 (代理+直连兜底)")

        for (idx, downloadURL) in proxyURLs.enumerated() {
            if Task.isCancelled { break }
            let isProxy = idx < proxyURLs.count - 1
            print("[UpdateManager] 下载尝试 #\(idx+1): \(isProxy ? "代理" : "直连") \(downloadURL.host ?? "")")

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
