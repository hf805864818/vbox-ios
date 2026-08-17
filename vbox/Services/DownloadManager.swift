import Foundation
import Combine
import CommonCrypto

// MARK: - 下载类型枚举

enum DownloadType {
    case m3u8
    case directFile
    case unsupported
}

// MARK: - DownloadManager

/// 下载管理器：负责接收下载任务、解析真实下载地址、执行文件下载、上报进度
/// 网盘资源统一调用 CloudDriveManager.resolvePlayURL(from:) 动态入口
/// 后期优化其他网盘解析链路后，下载功能自动支持，零改动
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published var activeDownloads: [DownloadRecord] = []
    @Published var capsuleMessage: DownloadCapsuleMessage?  // 胶囊通知消息

    private var downloadTasks: [Int: Task<Void, Never>] = [:]  // recordId → Task
    private let maxConcurrent = 2  // 最大并发下载数
    private var pendingQueue: [DownloadRecord] = []
    private var lastStatusMap: [Int: String] = [:]  // 跟踪状态变化：recordId → 旧状态

    private init() {}

    // MARK: - 入队

    func enqueueDownload(record: DownloadRecord) {
        DatabaseManager.shared.addDownload(record)
        reloadActiveDownloads()

        // addDownload 按值传递，record.id 不会被回填
        // 需要重新查询获取数据库分配的 id
        guard let savedRecord = findMatchingRecord(record) else {
            print("[DownloadManager] 无法找到刚插入的下载记录")
            return
        }

        // 发送胶囊通知：正在下载
        postCapsule(
            text: "已添加「\(savedRecord.name)」到下载",
            icon: "arrow.down.circle.fill",
            type: .info
        )

        if downloadTasks.count < maxConcurrent {
            startDownload(record: savedRecord)
        } else {
            pendingQueue.append(savedRecord)
        }
    }

    // MARK: - 胶囊通知

    /// 发送胶囊通知（自动 2.5 秒后清除）
    private func postCapsule(text: String, icon: String, type: DownloadCapsuleMessage.CapsuleType) {
        let msg = DownloadCapsuleMessage(text: text, icon: icon, type: type)
        DispatchQueue.main.async { [weak self] in
            self?.capsuleMessage = msg
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                if self?.capsuleMessage?.id == msg.id {
                    self?.capsuleMessage = nil
                }
            }
        }
    }

    /// 根据名称和添加时间查找刚插入的记录，获取数据库分配的 id
    private func findMatchingRecord(_ record: DownloadRecord) -> DownloadRecord? {
        let all = DatabaseManager.shared.queryDownloads()
        // 按名称+播放地址匹配，取最新一条
        return all.first(where: { $0.name == record.name && $0.playurl == record.playurl })
    }

    // MARK: - 刷新列表

    func reloadActiveDownloads() {
        activeDownloads = DatabaseManager.shared.queryDownloads()
        checkStatusChanges()
    }

    /// 检测下载状态变化，自动发送胶囊通知
    private func checkStatusChanges() {
        for record in activeDownloads {
            guard let recordId = record.id else { continue }
            let oldStatus = lastStatusMap[recordId]
            let newStatus = record.status

            // 状态未变化或首次记录（跳过首次，避免初始化时误报）
            if oldStatus == newStatus { continue }
            if oldStatus == nil {
                lastStatusMap[recordId] = newStatus
                continue
            }

            // 状态发生变化
            switch newStatus {
            case "completed":
                postCapsule(
                    text: "「\(record.name)」下载完成",
                    icon: "checkmark.circle.fill",
                    type: .success
                )
            case "failed":
                // 区分网络失败和普通失败
                let isNetworkError = record.downloadedSize == 0
                postCapsule(
                    text: "「\(record.name)」\(isNetworkError ? "网络失败" : "下载失败")",
                    icon: isNetworkError ? "wifi.slash" : "xmark.circle.fill",
                    type: isNetworkError ? .network : .failure
                )
            default:
                break
            }

            lastStatusMap[recordId] = newStatus
        }

        // 清理已删除记录的状态跟踪
        let currentIds = Set(activeDownloads.compactMap { $0.id })
        lastStatusMap = lastStatusMap.filter { currentIds.contains($0.key) }
    }

    // MARK: - 启动下载

    private func startDownload(record: DownloadRecord) {
        let taskId = record.id ?? 0
        let task = Task { [weak self] in
            await self?.executeDownload(record: record)
            await MainActor.run {
                self?.downloadTasks.removeValue(forKey: taskId)
                self?.startNextPending()
            }
        }
        downloadTasks[taskId] = task
    }

    private func startNextPending() {
        guard downloadTasks.count < maxConcurrent, !pendingQueue.isEmpty else { return }
        let next = pendingQueue.removeFirst()
        startDownload(record: next)
    }

    // MARK: - 核心执行

    private func executeDownload(record: DownloadRecord) async {
        let recordId = record.id ?? 0
        guard recordId > 0 else { return }

        // 步骤1: 更新状态为 downloading
        DatabaseManager.shared.updateDownloadStatus(id: recordId, status: "downloading")
        await MainActor.run { reloadActiveDownloads() }

        // 步骤2: 解析真实下载地址
        let resolved = await resolveDownloadURL(record: record)

        switch resolved.type {
        case .m3u8:
            await downloadM3U8(record: record, url: resolved.url, headers: resolved.headers)
        case .directFile:
            await downloadDirectFile(record: record, url: resolved.url, headers: resolved.headers)
        case .unsupported:
            DatabaseManager.shared.updateDownloadStatus(id: recordId, status: "failed")
            await MainActor.run { reloadActiveDownloads() }
        }
    }

    // MARK: - 地址解析（按 sourceType 分发）
    // 网盘资源统一走 resolvePlayURL(from:) 动态入口，无需按类型硬编码

    private func resolveDownloadURL(record: DownloadRecord) async
        -> (url: String, headers: [String: String], type: DownloadType) {

        let sourceType = record.sourceType ?? "normal"

        if sourceType == "cloud" {
            return await resolveCloudDriveURL(record: record)
        } else {
            return await resolveNormalURL(record: record)
        }
    }

    // MARK: - 普通资源解析

    private func resolveNormalURL(record: DownloadRecord) async
        -> (url: String, headers: [String: String], type: DownloadType) {

        let url = record.playurl

        // 1. 如果是媒体直链，直接返回
        if isDirectMediaURL(url) {
            let type: DownloadType = url.lowercased().contains("m3u8") ? .m3u8 : .directFile
            return (url, [:], type)
        }

        // 2. 调用 SpiderManager.getPlayerContent（JS 蜘蛛 playerContent）
        if let engineKey = record.engineKey, !engineKey.isEmpty,
           let vodId = record.vodId, !vodId.isEmpty {
            if let pr = await SpiderManager.shared.getPlayerContent(
                vodId: vodId, flag: "play", url: url, engineKey: engineKey) {
                let resolvedUrl = pr.playUrl.flatMap { $0.isEmpty ? nil : $0 } ?? pr.url ?? ""
                if !resolvedUrl.isEmpty {
                    let type: DownloadType = resolvedUrl.lowercased().contains("m3u8") ? .m3u8 : .directFile
                    return (resolvedUrl, pr.header ?? [:], type)
                }
            }
        }

        // 3. 调用解析器兜底
        if let parsed = await SpiderManager.shared.parsePlayUrl(from: url) {
            let type: DownloadType = parsed.lowercased().contains("m3u8") ? .m3u8 : .directFile
            return (parsed, [:], type)
        }

        return ("", [:], .unsupported)
    }

    // MARK: - 网盘资源解析（动态统一入口）

    /// 一行调用 resolvePlayURL(from:)，复用播放器的全部网盘解析能力
    /// 自动完成：网盘类型检测 → Token 获取 → 多 Token 遍历 → vbox 参数解析 → 失败标记
    /// 后期优化其他网盘解析链路后，下载自动支持，零改动
    private func resolveCloudDriveURL(record: DownloadRecord) async
        -> (url: String, headers: [String: String], type: DownloadType) {

        let shareURL = record.playurl

        do {
            let playResult = try await CloudDriveManager.shared.resolvePlayURL(from: shareURL)
            let type: DownloadType = playResult.url.lowercased().contains("m3u8")
                                     ? .m3u8 : .directFile
            return (playResult.url, playResult.headers, type)
        } catch {
            print("[DownloadManager] 网盘解析失败: \(error.localizedDescription)")
            return ("", [:], .unsupported)
        }
    }

    // MARK: - 直链文件下载器

    private func downloadDirectFile(record: DownloadRecord, url: String,
                                     headers: [String: String]) async {
        let recordId = record.id ?? 0
        guard let downloadURL = URL(string: url) else {
            DatabaseManager.shared.updateDownloadStatus(id: recordId, status: "failed")
            await MainActor.run { reloadActiveDownloads() }
            return
        }

        var request = URLRequest(url: downloadURL)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        do {
            let (saveURL, response) = try await URLSession.shared.download(for: request)

            // 确定文件扩展名
            let ext = downloadURL.pathExtension.isEmpty
                ? "mp4" : downloadURL.pathExtension

            // 创建下载目录
            let downloadsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

            // 清理文件名中的非法字符
            let safeName = record.name.replacingOccurrences(of: "[/\\:*?\"<>|]", with: "_", options: .regularExpression)
            let outputURL = downloadsDir.appendingPathComponent("\(safeName).\(ext)")

            // 如果文件已存在，先删除
            try? FileManager.default.removeItem(at: outputURL)
            try FileManager.default.moveItem(at: saveURL, to: outputURL)

            let fileSize = (try? FileManager.default.attributesOfItem(
                atPath: outputURL.path)[.size] as? Int64) ?? 0

            DatabaseManager.shared.updateDownloadPath(
                id: recordId, path: outputURL.path,
                fileSize: fileSize, status: "completed")
            await MainActor.run { reloadActiveDownloads() }

        } catch {
            print("[DownloadManager] 直链下载失败: \(error.localizedDescription)")
            DatabaseManager.shared.updateDownloadStatus(id: recordId, status: "failed")
            await MainActor.run { reloadActiveDownloads() }
        }
    }

    // MARK: - M3U8 下载器

    private func downloadM3U8(record: DownloadRecord, url: String,
                               headers: [String: String]) async {
        let recordId = record.id ?? 0

        // 1. 下载 m3u8 播放列表
        guard let m3u8Content = await fetchString(url: url, headers: headers) else {
            DatabaseManager.shared.updateDownloadStatus(id: recordId, status: "failed")
            await MainActor.run { reloadActiveDownloads() }
            return
        }

        // 2. 处理 master playlist（多码率）→ 取第一个 media playlist
        let mediaPlaylistURL = resolveMediaPlaylist(from: m3u8Content, baseURL: url)
        let finalContent: String
        let finalBaseURL: String

        if mediaPlaylistURL != url {
            guard let content = await fetchString(url: mediaPlaylistURL, headers: headers) else {
                DatabaseManager.shared.updateDownloadStatus(id: recordId, status: "failed")
                await MainActor.run { reloadActiveDownloads() }
                return
            }
            finalContent = content
            finalBaseURL = mediaPlaylistURL
        } else {
            finalContent = m3u8Content
            finalBaseURL = url
        }

        // 3. 解析 TS 分片 URL 列表
        let tsURLs = parseTSSegments(from: finalContent, baseURL: finalBaseURL)
        guard !tsURLs.isEmpty else {
            DatabaseManager.shared.updateDownloadStatus(id: recordId, status: "failed")
            await MainActor.run { reloadActiveDownloads() }
            return
        }

        // 4. 处理 AES-128 加密
        let keyInfo = extractAESKeyInfo(from: finalContent, baseURL: finalBaseURL)
        var aesKey: Data? = nil
        if let keyURL = keyInfo?.url {
            aesKey = await fetchData(url: keyURL, headers: headers)
        }

        // 5. 创建临时目录
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbox_dl_\(recordId)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 6. 逐个下载 TS 分片
        for (index, tsURL) in tsURLs.enumerated() {
            if Task.isCancelled { return }

            guard let tsData = await fetchData(url: tsURL, headers: headers) else { continue }

            let finalData: Data
            if let key = aesKey, let iv = keyInfo?.iv {
                finalData = decryptTS(data: tsData, key: key, iv: iv)
            } else if let key = aesKey {
                // 默认 IV = 序号
                let ivBytes = withUnsafeBytes(of: UInt64(index).bigEndian) { Data($0) }
                let ivData = Data(repeating: 0, count: 8) + ivBytes
                finalData = decryptTS(data: tsData, key: key, iv: ivData)
            } else {
                finalData = tsData
            }

            let tsPath = tempDir.appendingPathComponent(
                "seg_\(String(format: "%05d", index)).ts")
            try? finalData.write(to: tsPath)

            // 7. 上报进度
            let progress = Double(index + 1) / Double(tsURLs.count)
            let currentSize = dirSize(tempDir)
            DatabaseManager.shared.updateDownloadProgress(
                id: recordId, progress: progress,
                downloadedSize: currentSize, status: "downloading")
            await MainActor.run { reloadActiveDownloads() }
        }

        // 8. 合并 TS → 单个文件
        let downloadsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let safeName = record.name.replacingOccurrences(of: "[/\\:*?\"<>|]", with: "_", options: .regularExpression)
        let outputURL = downloadsDir.appendingPathComponent("\(safeName).ts")

        mergeTSSegments(in: tempDir, to: outputURL)

        // 9. 清理临时文件 + 标记完成
        try? FileManager.default.removeItem(at: tempDir)

        let fileSize = (try? FileManager.default.attributesOfItem(
            atPath: outputURL.path)[.size] as? Int64) ?? 0

        DatabaseManager.shared.updateDownloadPath(
            id: recordId, path: outputURL.path,
            fileSize: fileSize, status: "completed")
        await MainActor.run { reloadActiveDownloads() }
    }

    // MARK: - 暂停/继续/删除

    func cancelDownload(id: Int) {
        downloadTasks[id]?.cancel()
        downloadTasks.removeValue(forKey: id)
        DatabaseManager.shared.updateDownloadStatus(id: id, status: "failed")
        reloadActiveDownloads()
    }

    func retryDownload(id: Int) {
        let records = DatabaseManager.shared.queryDownloads()
        guard let record = records.first(where: { $0.id == id }) else { return }
        DatabaseManager.shared.updateDownloadStatus(id: id, status: "pending")
        DatabaseManager.shared.updateDownloadProgress(id: id, progress: 0, downloadedSize: 0, status: "pending")
        reloadActiveDownloads()
        startDownload(record: record)
    }

    func clearCompleted() {
        let records = DatabaseManager.shared.queryDownloads()
        for record in records where record.status == "completed" {
            if !record.filePath.isEmpty {
                try? FileManager.default.removeItem(atPath: record.filePath)
            }
            DatabaseManager.shared.deleteDownload(id: record.id ?? 0)
        }
        reloadActiveDownloads()
    }

    // MARK: - 辅助方法

    private func isDirectMediaURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        let mediaExts = [".m3u8", ".mp4", ".mkv", ".flv", ".avi", ".mov", ".ts", ".m4a", ".mp3"]
        // 包含媒体扩展名，或者是 http(s) 开头且不含网盘域名
        if mediaExts.contains(where: { lower.contains($0) }) { return true }
        // 非网盘 URL 且是 http(s) 直链
        if lower.hasPrefix("http") {
            let cloudDomains = ["pan.baidu.com", "pan.quark.cn", "aliyundrive.com", "alipan.com",
                                "uc.cn", "ucloud.cn", "115.com", "123pan.com", "123cloud.cn",
                                "yun.139.com", "139.com", "cloud.189.cn", "189.cn",
                                "pan.xunlei.com"]
            if !cloudDomains.contains(where: { lower.contains($0) }) {
                return true
            }
        }
        return false
    }

    private func fetchString(url: String, headers: [String: String]) async -> String? {
        guard let fetchURL = URL(string: url) else { return nil }
        var request = URLRequest(url: fetchURL)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return String(data: data, encoding: .utf8)
        } catch {
            print("[DownloadManager] fetchString 失败: \(error.localizedDescription)")
            return nil
        }
    }

    private func fetchData(url: String, headers: [String: String]) async -> Data? {
        guard let fetchURL = URL(string: url) else { return nil }
        var request = URLRequest(url: fetchURL)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            return data
        } catch {
            print("[DownloadManager] fetchData 失败: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - M3U8 解析辅助

    private func resolveMediaPlaylist(from content: String, baseURL: String) -> String {
        // 如果包含 #EXT-X-STREAM-INF（master playlist），取第一个子 playlist
        let lines = content.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            if line.contains("#EXT-X-STREAM-INF") {
                // 下一行是子 playlist URL
                if i + 1 < lines.count {
                    let nextLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
                    return resolveURL(nextLine, baseURL: baseURL)
                }
            }
        }
        return baseURL
    }

    private func parseTSSegments(from content: String, baseURL: String) -> [String] {
        var segments: [String] = []
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            segments.append(resolveURL(trimmed, baseURL: baseURL))
        }
        return segments
    }

    private struct AESKeyInfo {
        let url: String?
        let iv: Data?
    }

    private func extractAESKeyInfo(from content: String, baseURL: String) -> AESKeyInfo? {
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("#EXT-X-KEY") {
                // 解析 URI="..." 和 IV=0x...
                var keyURL: String?
                var iv: Data?

                if let uriRange = line.range(of: "URI=\"") {
                    let start = uriRange.upperBound
                    if let endRange = line[start...].range(of: "\"") {
                        let uri = String(line[start..<endRange.lowerBound])
                        keyURL = resolveURL(uri, baseURL: baseURL)
                    }
                }

                if let ivRange = line.range(of: "IV=0x") {
                    let start = ivRange.upperBound
                    let hexStr = String(line[start...]).trimmingCharacters(in: .whitespaces)
                    if let data = dataFromHex(hexStr) {
                        iv = data
                    }
                }

                return AESKeyInfo(url: keyURL, iv: iv)
            }
        }
        return nil
    }

    private func resolveURL(_ relative: String, baseURL: String) -> String {
        if relative.hasPrefix("http://") || relative.hasPrefix("https://") {
            return relative
        }
        guard let base = URL(string: baseURL) else { return relative }
        if let resolved = URL(string: relative, relativeTo: base) {
            return resolved.absoluteString
        }
        return relative
    }

    private func dataFromHex(_ hex: String) -> Data? {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2, limitedBy: cleaned.endIndex) ?? cleaned.endIndex
            if let byte = UInt8(cleaned[index..<nextIndex], radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        return data.isEmpty ? nil : data
    }

    private func decryptTS(data: Data, key: Data, iv: Data) -> Data {
        // AES-128-CBC 一次性解密（每个 TS 分片独立解密）
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var bytesWritten = 0

        let status = buffer.withUnsafeMutableBytes { bufferPtr -> CCCryptorStatus in
            data.withUnsafeBytes { dataPtr -> CCCryptorStatus in
                key.withUnsafeBytes { keyPtr -> CCCryptorStatus in
                    iv.withUnsafeBytes { ivPtr -> CCCryptorStatus in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress!, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress!, data.count,
                            bufferPtr.baseAddress!, bufferSize,
                            &bytesWritten
                        )
                    }
                }
            }
        }

        if status == kCCSuccess && bytesWritten > 0 {
            return buffer.prefix(bytesWritten)
        }
        return data
    }

    private func mergeTSSegments(in tempDir: URL, to outputURL: URL) {
        // 简单合并：按序号拼接所有 TS 文件
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: nil) else { return }

        let sortedFiles = files.sorted { $0.lastPathComponent < $1.lastPathComponent }

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let fileHandle = try? FileHandle(forWritingTo: outputURL) else { return }

        for file in sortedFiles {
            if let data = try? Data(contentsOf: file) {
                fileHandle.write(data)
            }
        }
        try? fileHandle.close()
    }

    private func dirSize(_ url: URL) -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var size: Int64 = 0
        for file in files {
            if let fileSize = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                size += Int64(fileSize)
            }
        }
        return size
    }
}
