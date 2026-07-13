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

    // MARK: - 代理节点缓存

    private struct ProxyCache: Codable {
        let nodes: [String]
        let timestamp: Date
    }

    private let proxyCacheKey = "vbox_proxy_nodes_cache"
    private let proxyCacheTTL: TimeInterval = 300 // 5分钟

    /// 从 github.akams.cn 获取实测最快的代理节点列表
    private func fetchProxyNodes() async -> [String] {
        // 先读缓存
        if let cached = readProxyCache(), Date().timeIntervalSince(cached.timestamp) < proxyCacheTTL {
            print("[UpdateManager] 使用缓存的代理节点: \(cached.nodes.count)个")
            return cached.nodes
        }

        do {
            var request = URLRequest(url: URL(string: "https://github.akams.cn")!)
            request.timeoutInterval = 8
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { throw NSError(domain: "", code: -1) }

            let nodes = parseProxyNodes(from: html)
            if nodes.isEmpty { throw NSError(domain: "", code: -1) }

            print("[UpdateManager] 从 github.akams.cn 解析到 \(nodes.count) 个节点，最快: \(nodes.first ?? "none")")
            saveProxyCache(nodes: nodes)
            return nodes
        } catch {
            print("[UpdateManager] 获取代理节点失败: \(error.localizedDescription)，使用默认节点")
            return fallbackProxyNodes()
        }
    }

    /// 解析页面中所有 (域名, 延迟) 对，按延迟升序排列
    private func parseProxyNodes(from html: String) -> [String] {
        // 匹配模式: 域名 延迟数字 单位(ms|s)
        // 例: "github.starrlzy.cn388 ms" → host=github.starrlzy.cn, delay=388ms
        //     "j.1win.ggff.net1.11 s"  → host=j.1win.ggff.net, delay=1110ms
        //     "gh.llkk.cc--"           → 不匹配（离线节点，自动过滤）
        let pattern = #"(([a-zA-Z0-9][-a-zA-Z0-9]*\.)+[a-zA-Z]{2,})-*(\d+\.?\d*)\s*(ms|s)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }

        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, options: [], range: range)

        var nodeDelays: [(host: String, delayMs: Double)] = []

        for match in matches {
            // group 1 = 域名, group 3 = 延迟数字, group 4 = 单位(ms/s)
            guard let hostRange = Range(match.range(at: 1), in: html),
                  let delayRange = Range(match.range(at: 3), in: html),
                  let unitRange = Range(match.range(at: 4), in: html) else { continue }

            let host = String(html[hostRange])
            let delayValue = Double(html[delayRange]) ?? 0
            let unit = String(html[unitRange])

            guard !host.isEmpty, host.contains(".") else { continue }

            let delayMs = unit == "s" ? delayValue * 1000 : delayValue
            nodeDelays.append((host: host, delayMs: delayMs))
        }

        // 去重，按延迟升序排列
        var seen = Set<String>()
        let unique = nodeDelays.filter { seen.insert($0.host).inserted }
        return unique.sorted { $0.delayMs < $1.delayMs }.map { $0.host }
    }

    private func fallbackProxyNodes() -> [String] {
        return ["ghproxy.net", "ghproxy.com", "gh.con.sh", "gh.llkk.cc", "github.starrlzy.cn"]
    }

    private func readProxyCache() -> ProxyCache? {
        guard let data = UserDefaults.standard.data(forKey: proxyCacheKey),
              let cache = try? JSONDecoder().decode(ProxyCache.self, from: data) else { return nil }
        return cache
    }

    private func saveProxyCache(nodes: [String]) {
        let cache = ProxyCache(nodes: nodes, timestamp: Date())
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: proxyCacheKey)
        }
    }

    /// 执行实际下载
    private func performDownload(from url: URL) async {
        isDownloading = true
        downloadProgress = 0
        downloadError = nil
        downloadedIPAPath = nil

        let tempDir = FileManager.default.temporaryDirectory
        let destinationURL = tempDir.appendingPathComponent("vbox_update.ipa")

        // 删除旧文件
        try? FileManager.default.removeItem(at: destinationURL)

        // 动态获取最快代理节点，组装下载 URL 列表
        let urlStr = url.absoluteString
        let dynamicNodes = await fetchProxyNodes()
        var proxyURLs: [URL] = dynamicNodes.map { URL(string: "https://\($0)/\(urlStr)")! }
        proxyURLs.append(url) // 兜底：原始地址

        print("[UpdateManager] 下载源: \(proxyURLs.map { $0.host ?? "?" }.joined(separator: ", "))")

        for (idx, downloadURL) in proxyURLs.enumerated() {
            if Task.isCancelled { break }
            let isProxy = idx < proxyURLs.count - 1
            print("[UpdateManager] 下载尝试 #\(idx+1): \(isProxy ? "代理" : "直连") \(downloadURL.host ?? "")")

            do {
                var request = URLRequest(url: downloadURL)
                request.timeoutInterval = 600 // 超时10分钟
                request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

                let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    print("[UpdateManager] #\(idx+1) 返回非200，尝试下一个")
                    continue
                }

                let totalBytes = httpResponse.expectedContentLength
                var receivedBytes: Int64 = 0
                var lastReportBytes: Int64 = 0
                var lastReportTime = Date()

                FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
                let fileHandle = try FileHandle(forWritingTo: destinationURL)

                let bufferSize = 256 * 1024 // 256KB（增大缓冲提升写效率）
                var buffer = Data()

                for try await byte in asyncBytes {
                    buffer.append(byte)
                    receivedBytes += 1

                    if buffer.count >= bufferSize {
                        try fileHandle.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)

                        if totalBytes > 0 {
                            let progress = Double(receivedBytes) / Double(totalBytes)
                            downloadProgress = min(progress, 0.999)
                        }

                        // 每秒打印一次下载速度
                        let now = Date()
                        let elapsed = now.timeIntervalSince(lastReportTime)
                        if elapsed >= 1.0 {
                            let bytesInInterval = receivedBytes - lastReportBytes
                            let speedKB = Double(bytesInInterval) / elapsed / 1024.0
                            print("[UpdateManager] 下载进度: \(Int(downloadProgress*100))% 速度: \(String(format: "%.0f", speedKB))KB/s")
                            lastReportBytes = receivedBytes
                            lastReportTime = now
                        }
                    }
                }

                if !buffer.isEmpty {
                    try fileHandle.write(contentsOf: buffer)
                }
                try fileHandle.close()

                downloadProgress = 1.0
                downloadedIPAPath = destinationURL
                print("[UpdateManager] IPA 下载完成: \(destinationURL.path)")
                isDownloading = false
                return

            } catch {
                if Task.isCancelled { break }
                print("[UpdateManager] #\(idx+1) 下载失败: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: destinationURL)
                // 继续尝试下一个 URL
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
