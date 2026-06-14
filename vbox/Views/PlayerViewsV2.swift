import SwiftUI
import AVKit
import AVFoundation
import Combine
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

extension Notification.Name {
    static let vboxVLCPlay = Notification.Name("vbox.vlc.play")
    static let vboxVLCPause = Notification.Name("vbox.vlc.pause")
    static let vboxVLCSeek = Notification.Name("vbox.vlc.seek")
    static let vboxVLCSpeed = Notification.Name("vbox.vlc.speed")
    static let vboxMPVPlay = Notification.Name("vbox.mpv.play")
    static let vboxMPVPause = Notification.Name("vbox.mpv.pause")
    static let vboxMPVSeek = Notification.Name("vbox.mpv.seek")
    static let vboxMPVSpeed = Notification.Name("vbox.mpv.speed")
}

// 屏幕方向辅助类
class OrientationHelper {
    static func lockOrientation(_ orientation: UIInterfaceOrientationMask) {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
        }
    }
    
    static func unlockOrientation() {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .all))
        }
    }
    
    static func rotateToLandscape() {
        // 方案1: UIDevice 私有API（最可靠）
        UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
        // 方案2: requestGeometryUpdate 公开API
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
        }
        // 方案3: 触发系统旋转
        UINavigationController.attemptRotationToDeviceOrientation()
    }
}

// MARK: - 新版本播放器 (爱奇艺风格) - 简化版本，确保编译通过
struct VideoPlayerViewV2: View {
    let video: VodItem
    @StateObject private var playerState = PlayerState()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 播放器主体 - 始终显示，包含加载状态
            PlayerContainerView(
                player: playerState.player,
                playerState: playerState,
                video: video
            )
            
            // 错误提示（附带调试日志）
            if let error = playerState.loadError {
                ErrorViewWithLogs(error: error, logs: playerState.debugLogs, onRetry: { playerState.retry(video: video) })
            }

            // 调试日志浮层（开关控制，加载中+播放中都显示）
            // 放在顶部返回按钮右侧的小窗，避免覆盖底部进度条 / 锁定按钮
            if UserDefaults.standard.bool(forKey: "show_debug_overlay") && !playerState.debugLogs.isEmpty {
                VStack {
                HStack(alignment: .top, spacing: 0) {
                    // 左侧返回按钮预留区，确保不覆盖
                    Spacer().frame(width: 96)

                    ScrollView(showsIndicators: true) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(playerState.debugLogs.enumerated()), id: \.offset) { idx, log in
                                Text(log)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.green.opacity(0.9))
                                    .id(idx)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                        }
                        .padding(6)
                    }
                    .frame(maxWidth: 560)
                    .frame(height: 126)
                    .background(Color.black.opacity(0.75))
                    .cornerRadius(6)
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)

                    // 右侧锁定按钮预留区，避免遮挡
                    Spacer().frame(width: 96)
                }
                .padding(.top, 12)
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear {
            // 强制横屏
            OrientationHelper.rotateToLandscape()
            playerState.setupPlayer(video: video)
        }
        .onDisappear {
            // 恢复竖屏
            OrientationHelper.lockOrientation(.portrait)
            OrientationHelper.unlockOrientation()
            playerState.cleanup()
        }
    }
}

// MARK: - 播放器状态管理
class PlayerState: ObservableObject {
    enum PlaybackEngineMode: String {
        case system = "系统内核"
        case compatibility = "兼容内核"
    }

    enum PlaybackEnginePreference: String, CaseIterable, Identifiable {
        case auto = "自动"
        case system = "系统"
        case vlc = "VLC"
        case mpv = "MPV"

        var id: String { rawValue }

        var subtitle: String {
            switch self {
            case .auto:
                return "普通资源走系统内核，特殊格式自动走兼容内核"
            case .system:
                return "强制使用 AVPlayer，适合普通 MP4"
            case .vlc:
                return "优先使用 VLC，适合 MKV / HEVC / 多音轨"
            case .mpv:
                return "预留选项，等待后续接入 libmpv framework"
            }
        }
    }

    @Published var player: AVPlayer?
    @Published var isPlaying = true
    @Published var showControls = true
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isSeeking = false
    @Published var seekPreviewTime: Double = 0
    @Published var isLoading = true
    @Published var loadError: String?
    @Published var showSettings = false
    @Published var showEpisodePicker = false
    @Published var showQualityPicker = false
    @Published var showDanmakuSettings = false
    @Published var showEnginePicker = false
    @Published var loadingMessage = "正在解析播放地址..."
    @Published var selectedQuality = 1
    @Published var playbackSpeed: Double = 1.0
    @Published var showDanmaku = true
    @Published var danmakuOpacity: Double = 0.8
    @Published var danmakuFontSize: CGFloat = 16
    @Published var isOrientationLocked = false
    @Published var volume: Double = 0.5
    @Published var brightness: Double = 0.5
    @Published var danmakuItems: [DanmakuRenderItem] = []
    @Published var danmakuLoadedCount = 0
    @Published var currentEpisodeIndex = 0
    @Published var debugLogs: [String] = []  // 可视化调试日志
    @Published var playbackEngineMode: PlaybackEngineMode = .system
    @Published var compatibilityHint: String?
    @Published var compatibilityURL: URL?
    @Published var compatibilityHeaders: [String: String] = [:]
    @Published var compatibilityEngineName: String = "VLC"
    @Published var enginePreference: PlaybackEnginePreference = .auto
    @Published var baiduFileList: [BaiduFileItem] = [] // 百度多文件列表
    @Published var baiduShareURL: String = ""    // 百度分享链接
    var baiduBduss: String = ""                  // 百度Token
    var baiduPcsCookie: String = ""              // 百度PCS下载Cookie
    private var currentVideo: VodItem?
    private var allDanmakuItems: [LogVarDanmakuItem] = []
    private var emittedDanmakuIDs = Set<Int>()
    private var danmakuTask: Task<Void, Never>?
    private var lastProgressSaveAt: Date = .distantPast
    private var baiduStreamRetryCount = 0        // 百度PCS流403后自动刷新直链次数
    private var baiduPrefetchTask: Task<Void, Never>?
    private var baiduPrefetchingIds = Set<String>()
    private var baiduNearEndPrefetchedIndexes = Set<Int>()
    private var quarkFallbackURL: String?
    private var quarkFallbackHeaders: [String: String]?
    private var quarkFallbackSource: String?
    private var quarkFallbackAttempted = false
    private var quarkFallbackTimeoutTask: Task<Void, Never>?
    private var m3u8ProbeCache: [String: M3U8ProbeCacheEntry] = [:]

    private enum M3U8PlaylistKind: String {
        case fmp4 = "hls-fmp4"
        case ts = "hls-ts"
        case unknown = "hls-unknown"
    }

    private struct M3U8ProbeCacheEntry {
        let kind: M3U8PlaylistKind
        let expiresAt: Date
    }

    private var isVLCBuildAvailable: Bool {
        #if canImport(MobileVLCKit)
        return true
        #else
        return false
        #endif
    }

    private var isMPVBuildAvailable: Bool {
        #if canImport(Libmpv)
        return true
        #else
        return false
        #endif
    }

    private var shouldUseCompatibilityEngine: Bool {
        switch enginePreference {
        case .auto:
            return playbackEngineMode == .compatibility && (isMPVBuildAvailable || isVLCBuildAvailable)
        case .system:
            return false
        case .vlc:
            return isVLCBuildAvailable
        case .mpv:
            return isMPVBuildAvailable
        }
    }

    var currentEngineButtonTitle: String {
        switch enginePreference {
        case .auto:
            if playbackEngineMode == .compatibility {
                return isMPVBuildAvailable ? "自动/MPV" : "自动/VLC"
            }
            return "自动"
        case .system:
            return "系统"
        case .vlc:
            return "VLC"
        case .mpv:
            return "MPV"
        }
    }

    private func preferredCompatibilityEngineName(for url: URL? = nil) -> String {
        switch enginePreference {
        case .mpv:
            return isMPVBuildAvailable ? "MPV-MoltenVK" : "VLC"
        case .vlc:
            return isVLCBuildAvailable ? "VLC" : (isMPVBuildAvailable ? "MPV-MoltenVK" : "VLC")
        case .auto:
            if isMPVBuildAvailable, shouldPreferMPV(for: url) {
                return "MPV-MoltenVK"
            }
            if isVLCBuildAvailable {
                return "VLC"
            }
            return isMPVBuildAvailable ? "MPV-MoltenVK" : "VLC"
        case .system:
            return "系统"
        }
    }

    private func shouldPreferMPV(for url: URL?) -> Bool {
        guard let url else { return compatibilityHint != nil }
        let text = url.absoluteString.lowercased()
        if text.contains("baidu-stream") { return true }
        if text.contains(".mkv") || text.contains("mkv") { return true }
        if compatibilityHint?.contains("MKV") == true { return true }
        if compatibilityHint?.contains("百度原画") == true { return true }
        return false
    }

    private func compatibilityReason(for fileName: String) -> String? {
        let lower = fileName.lowercased()
        let rules: [(String, String)] = [
            (".mkv", "MKV 封装"),
            ("hevc", "HEVC/H.265"),
            ("h265", "HEVC/H.265"),
            ("x265", "HEVC/H.265"),
            ("10bit", "10bit 视频"),
            ("hdr", "HDR 视频"),
            ("4k", "4K 高码率"),
            ("高码率", "高码率视频")
        ]
        return rules.first(where: { lower.contains($0.0) })?.1
    }

    func selectPlaybackEngine(_ preference: PlaybackEnginePreference) {
        enginePreference = preference
        showEnginePicker = false
        switch preference {
        case .auto:
            log("[PlayerV2] 已切换内核策略：自动")
        case .system:
            log("[PlayerV2] 已切换内核策略：系统内核")
        case .vlc:
            log("[PlayerV2] 已切换内核策略：VLC\(isVLCBuildAvailable ? "" : "（当前构建未包含 VLC）")")
        case .mpv:
            log("[PlayerV2] 已切换内核策略：MPV-MoltenVK\(isMPVBuildAvailable ? "" : "（当前构建未包含 Libmpv）")")
        }

        if !baiduFileList.isEmpty, currentEpisodeIndex < baiduFileList.count {
            switchBaiduFile(index: currentEpisodeIndex)
        }
    }

    /// 切换百度多文件中的指定文件播放
    func switchBaiduFile(index: Int) {
        guard index >= 0, index < baiduFileList.count else { return }
        let file = baiduFileList[index]
        let url = baiduShareURL
        guard !url.isEmpty else { return }
        
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await self.startBaiduPlayback(
                shareURL: url,
                bduss: self.baiduBduss,
                pcsCookie: self.baiduPcsCookie,
                file: file,
                index: index,
                reason: "选集"
            )
        }
    }

    func seek(to seconds: Double) {
        if compatibilityURL != nil {
            guard duration.isFinite, duration > 0 else { return }
            let target = max(0, min(seconds, duration))
            isSeeking = true
            seekPreviewTime = target
            currentTime = target
            isLoading = false
            log("[PlayerV2] \(compatibilityEngineName) 拖拽进度跳转：\(formatDuration(target)) / \(formatDuration(duration))")
            let notification: Notification.Name = compatibilityEngineName.contains("MPV") ? .vboxMPVSeek : .vboxVLCSeek
            NotificationCenter.default.post(name: notification, object: nil, userInfo: ["seconds": target])
            isSeeking = false
            return
        }
        guard let player, duration.isFinite, duration > 0 else { return }
        let target = max(0, min(seconds, duration))
        let cmTime = CMTime(seconds: target, preferredTimescale: 600)
        isSeeking = true
        seekPreviewTime = target
        loadingMessage = "正在跳转到 \(formatDuration(target))..."
        isLoading = true
        log("[PlayerV2] 拖拽进度跳转：\(formatDuration(target)) / \(formatDuration(duration))")
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = target
                self.isSeeking = false
                self.isLoading = false
                if finished, self.isPlaying {
                    self.player?.play()
                }
            }
        }
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func playNextBaiduFile() {
        let next = currentEpisodeIndex + 1
        guard next < baiduFileList.count else {
            log("[Baidu] 已经是最后一集")
            return
        }
        switchBaiduFile(index: next)
    }

    func togglePlayback(player: AVPlayer?) {
        if let player {
            isPlaying ? player.pause() : player.play()
            isPlaying.toggle()
            return
        }
        guard compatibilityURL != nil else { return }
        if isPlaying {
            NotificationCenter.default.post(name: compatibilityEngineName.contains("MPV") ? .vboxMPVPause : .vboxVLCPause, object: nil)
        } else {
            NotificationCenter.default.post(name: compatibilityEngineName.contains("MPV") ? .vboxMPVPlay : .vboxVLCPlay, object: nil)
        }
        isPlaying.toggle()
    }

    func changePlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        if let player {
            player.rate = isPlaying ? Float(speed) : 0
        }
        if compatibilityURL != nil {
            let notification: Notification.Name = compatibilityEngineName.contains("MPV") ? .vboxMPVSpeed : .vboxVLCSpeed
            NotificationCenter.default.post(name: notification, object: nil, userInfo: ["speed": speed])
            log("[PlayerV2] \(compatibilityEngineName) 倍速切换：\(String(format: "%.2f", speed))X")
        }
    }

    func changeQuality(index: Int) {
        selectedQuality = index
        if !baiduFileList.isEmpty {
            log("[Baidu] 当前百度DLNA播放为源文件/原画链路，暂不支持转码清晰度切换")
        }
    }

    private func loadDanmaku(for video: VodItem, fileName: String) {
        danmakuTask?.cancel()
        allDanmakuItems = []
        danmakuItems = []
        emittedDanmakuIDs.removeAll()
        danmakuLoadedCount = 0

        let query = bestDanmakuQuery(video: video, fileName: fileName)
        guard !query.isEmpty else { return }
        log("[Danmaku] 开始匹配：\(query)")
        danmakuTask = Task { [weak self] in
            let items = await LogVarDanmakuService.shared.matchAndFetch(fileName: query)
            await MainActor.run {
                guard let self else { return }
                self.allDanmakuItems = items.sorted { $0.time < $1.time }
                self.danmakuLoadedCount = items.count
                self.emittedDanmakuIDs.removeAll()
                self.danmakuItems = []
                self.log(items.isEmpty ? "[Danmaku] 未匹配到弹幕" : "[Danmaku] 已加载 \(items.count) 条弹幕")
            }
        }
    }

    private func bestDanmakuQuery(video: VodItem, fileName: String) -> String {
        let candidate = (fileName as NSString).deletingPathExtension
        if candidate.count >= 4, candidate != "baidu-stream", candidate != "quark-stream" {
            return candidate
        }
        return video.vodName
    }

    func updateDanmaku(at time: Double) {
        guard showDanmaku, !allDanmakuItems.isEmpty, time.isFinite else { return }
        let windowStart = max(0, time - 0.4)
        let windowEnd = time + 0.8
        let newItems = allDanmakuItems
            .filter { $0.time >= windowStart && $0.time <= windowEnd && !emittedDanmakuIDs.contains($0.id) }
            .prefix(12)

        guard !newItems.isEmpty || !danmakuItems.isEmpty else { return }
        for item in newItems {
            emittedDanmakuIDs.insert(item.id)
        }
        let appended = newItems.map { item in
            DanmakuRenderItem(
                id: item.id,
                content: item.content,
                time: max(time, item.time),
                lane: abs(item.id) % 8,
                color: item.color,
                duration: 7.0
            )
        }
        danmakuItems = (danmakuItems + appended)
            .filter { time - $0.time < $0.duration }
    }

    private func playbackProgressKey(for video: VodItem) -> String {
        "playback_progress_v2_\(video.vodId)_\(currentEpisodeIndex)"
    }

    private func restorePlaybackProgress(for video: VodItem) {
        let key = playbackProgressKey(for: video)
        let saved = UserDefaults.standard.double(forKey: key)
        guard saved > 10 else { return }
        currentTime = saved
        seekPreviewTime = saved
        log("[Progress] 已恢复上次进度：\(formatDuration(saved))")
    }

    func savePlaybackProgress(force: Bool = false) {
        guard let video = currentVideo, currentTime.isFinite, currentTime > 5 else { return }
        if duration > 0, duration - currentTime < 15 {
            UserDefaults.standard.removeObject(forKey: playbackProgressKey(for: video))
            return
        }
        guard force || Date().timeIntervalSince(lastProgressSaveAt) > 5 else { return }
        lastProgressSaveAt = Date()
        UserDefaults.standard.set(currentTime, forKey: playbackProgressKey(for: video))
    }

    private func formatDuration(_ time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "00:00" }
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
    }

    /// 百度网盘统一播放入口：
    /// - 进入播放器：解析出文件列表后立即调用，默认播放第一集
    /// - 手动选集：带指定 fs_id 调用
    /// 这样不会只停在“文件列表成功”而不继续触发 Worker /play。
    private func startBaiduPlayback(
        shareURL: String,
        bduss: String,
        pcsCookie: String = "",
        file: BaiduFileItem,
        index: Int,
        reason: String
    ) async {
        let episodeNo = index + 1
        log("[Baidu] ②\(reason)第\(episodeNo)集：\(file.name)，主路链→原有链路兜底...")
        await MainActor.run {
            currentEpisodeIndex = index
            if let video = currentVideo {
                loadDanmaku(for: video, fileName: file.name)
                restorePlaybackProgress(for: video)
            }
            isLoading = true
            loadingMessage = "正在获取百度视频地址..."
            loadError = nil
            if let reason = compatibilityReason(for: file.name) {
                playbackEngineMode = .compatibility
                compatibilityHint = reason
                log("[PlayerV2] 当前资源疑似需要兼容内核：\(reason)")
            } else {
                playbackEngineMode = .system
                compatibilityHint = nil
            }
        }

        do {
            let resolveStart = Date()
            let result: PlayResult
            do {
                result = try await CloudDriveManager.shared.resolveBaiduPlayURLViaMainRoute(
                    shareURL: shareURL,
                    bduss: bduss,
                    fsId: file.fsId,
                    fileName: file.name,
                    pcsCookie: pcsCookie
                )
                log("[Baidu-MainRoute] ✅ 第\(episodeNo)集主路链播放地址获取成功，耗时=\(Int(Date().timeIntervalSince(resolveStart) * 1000))ms")
            } catch {
                log("[Baidu-MainRoute] ⚠️ 第\(episodeNo)集主路链失败，回落原百度播放链路：\(error.localizedDescription)")
                result = try await CloudDriveManager.shared.resolveBaiduPlayURL(
                    shareURL: shareURL,
                    bduss: bduss,
                    fsId: file.fsId,
                    pcsCookie: pcsCookie
                )
                log("[Baidu-Fallback] ✅ 第\(episodeNo)集原百度播放链路获取成功，累计耗时=\(Int(Date().timeIntervalSince(resolveStart) * 1000))ms")
            }
            if !reason.contains("刷新") && !reason.contains("重试") {
                baiduStreamRetryCount = 0
            }
            let source = result.source ?? "未知路链"
            log("[Baidu] 第\(episodeNo)集命中路链：\(source)")
            if source.contains("m3u8") || result.url.lowercased().contains(".m3u8") || result.url.contains("/share/streaming") {
                await MainActor.run {
                    playbackEngineMode = .system
                    compatibilityHint = nil
                }
                log("[Baidu] M3U8 兜底路链使用系统 HLS 内核")
            }
            let streamHeaders = mergedBaiduStreamHeaders(result.headers)
            await playDriveVideo(url: result.url, headers: streamHeaders)
        } catch let error as DriveError {
            let specificMsg: String
            switch error {
            case .noPlayURL(let reason): specificMsg = reason
            case .saveFailed: specificMsg = "转存失败"
            case .invalidResponse: specificMsg = "服务器响应异常"
            default: specificMsg = error.localizedDescription
            }
            log("[Baidu] ❌ 第\(episodeNo)集：\(specificMsg)")
            await MainActor.run {
                loadError = specificMsg
                isLoading = false
            }
        } catch {
            log("[Baidu] ❌ 第\(episodeNo)集：\(error.localizedDescription)")
            await MainActor.run {
                loadError = "百度播放失败: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    /// 添加调试日志（同时打印到控制台和UI）
    func log(_ msg: String) {
        print(msg)
        let short = msg.replacingOccurrences(of: "[PlayerV2] ", with: "")
        Task { @MainActor in
            debugLogs.append(short)
            if debugLogs.count > 30 { debugLogs.removeFirst() }
        }
    }

    private func logDrivePlayResult(_ result: PlayResult) {
        if result.driveType == .quark {
            log("[Quark] 主线路：\(result.source ?? "未知")，host=\(URL(string: result.url)?.host ?? "unknown")")
            if let fallbackURL = result.fallbackURL {
                log("[Quark] 兜底线路：\(result.fallbackSource ?? "未知")，host=\(URL(string: fallbackURL)?.host ?? "unknown")")
            } else {
                log("[Quark] 兜底线路：暂无")
            }
        }
    }

    private func playResolvedDriveVideo(_ result: PlayResult) async {
        if result.driveType == .quark {
            quarkFallbackTimeoutTask?.cancel()
            quarkFallbackAttempted = false
            quarkFallbackURL = result.fallbackURL
            quarkFallbackHeaders = result.fallbackHeaders
            quarkFallbackSource = result.fallbackSource
            logDrivePlayResult(result)
            await playDriveVideo(url: result.url, headers: result.headers)
        } else {
            quarkFallbackTimeoutTask?.cancel()
            quarkFallbackAttempted = false
            quarkFallbackURL = nil
            quarkFallbackHeaders = nil
            quarkFallbackSource = nil
            await playDriveVideo(url: result.url, headers: result.headers)
        }
    }

    @discardableResult
    private func switchToQuarkFallback(reason: String) -> Bool {
        guard !quarkFallbackAttempted,
              let url = quarkFallbackURL,
              !url.isEmpty else {
            log("[Quark] 兜底线路不可用，无法切换：\(reason)")
            return false
        }

        quarkFallbackAttempted = true
        quarkFallbackTimeoutTask?.cancel()
        let headers = quarkFallbackHeaders ?? [:]
        let source = quarkFallbackSource ?? "v2-play-m3u8"
        log("[Quark] 原画线路失败，切换兜底线路：\(source)，原因：\(reason)")

        Task { [weak self] in
            guard let self else { return }
            await self.playDriveVideo(url: url, headers: headers)
        }
        return true
    }

    private func scheduleQuarkPrimaryFallbackTimeout(playerItem: AVPlayerItem, startedAt: Date) {
        guard quarkFallbackURL != nil, !quarkFallbackAttempted else { return }
        quarkFallbackTimeoutTask?.cancel()
        quarkFallbackTimeoutTask = Task { [weak self, weak playerItem] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, let playerItem, !Task.isCancelled else { return }
            await MainActor.run {
                guard self.player?.currentItem === playerItem,
                      self.isLoading,
                      playerItem.status != .readyToPlay,
                      !self.quarkFallbackAttempted else { return }
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
                self.log("[Quark] 原画线路首帧超时 \(elapsed)ms，准备切换 m3u8 兜底")
                self.switchToQuarkFallback(reason: "首帧超时")
            }
        }
    }

    private func prefetchNextBaiduFile(after index: Int) {
        let nextIndex = index + 1
        guard nextIndex < baiduFileList.count else { return }
        guard !baiduShareURL.isEmpty else { return }
        let nextFile = baiduFileList[nextIndex]
        guard !nextFile.fsId.isEmpty, !baiduPrefetchingIds.contains(nextFile.fsId) else { return }
        baiduPrefetchingIds.insert(nextFile.fsId)
        let shareURL = baiduShareURL
        let bduss = baiduBduss
        let pcsCookie = baiduPcsCookie

        baiduPrefetchTask?.cancel()
        baiduPrefetchTask = Task { [weak self] in
            guard let self else { return }
            self.log("[Baidu-MainRoute] 开始预取下一集主路链 PlayItem：第\(nextIndex + 1)集 \(nextFile.name)")
            do {
                _ = try await CloudDriveManager.shared.resolveBaiduPlayURLViaMainRoute(
                    shareURL: shareURL,
                    bduss: bduss,
                    fsId: nextFile.fsId,
                    fileName: nextFile.name,
                    pcsCookie: pcsCookie
                )
                self.log("[Baidu-MainRoute] ✅ 第\(nextIndex + 1)集主路链 PlayItem 已准备")
            } catch {
                self.log("[Baidu-MainRoute] ⚠️ 第\(nextIndex + 1)集主路链预取失败，保留原链路兜底：\(error.localizedDescription)")
            }
            await MainActor.run {
                self.baiduPrefetchingIds.remove(nextFile.fsId)
            }
        }
    }

    private func mergedBaiduStreamHeaders(_ headers: [String: String]) -> [String: String] {
        var merged = headers
        let workerCookie = headerValue(headers, named: "Cookie")
            ?? headerValue(headers, named: "X-Baidu-Pcs-Cookie")
            ?? ""
        let webCookie = normalizeBaiduCookie(baiduBduss)
        let pcsCookie = normalizeBaiduCookie(baiduPcsCookie)
        let finalCookie = mergeCookieStrings([workerCookie, webCookie, pcsCookie])

        if !finalCookie.isEmpty {
            merged["Cookie"] = finalCookie
            merged["X-Baidu-Pcs-Cookie"] = finalCookie
        }

        if headerValue(merged, named: "User-Agent") == nil {
            merged["User-Agent"] = "netdisk;P2SP;2.2.101.236;netdisk;12.24.6;PHW110;android-android;12;JSbridge4.4.0;jointBridge;1.1.0;"
        }
        if headerValue(merged, named: "Referer") == nil {
            merged["Referer"] = "https://pan.baidu.com/"
        }

        let lowerCookie = finalCookie.lowercased()
        log("[Baidu] 本地代理合并Cookie：hasBDUSS=\(lowerCookie.contains("bduss=")), hasSTOKEN=\(lowerCookie.contains("stoken=")), hasPANPSC=\(lowerCookie.contains("panpsc=")), hasPTOKEN=\(lowerCookie.contains("ptoken"))")
        return merged
    }

    private func headerValue(_ headers: [String: String], named name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }

    private func normalizeBaiduCookie(_ raw: String) -> String {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return "" }
        if input.lowercased().hasPrefix("cookie:") {
            input = String(input.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if input.range(of: #"BDUSS=|PANPSC=|PTOKEN|STOKEN=|BAIDUID="#, options: [.regularExpression, .caseInsensitive]) != nil {
            return input
                .replacingOccurrences(of: "\n", with: "; ")
                .replacingOccurrences(of: "\r", with: "; ")
                .replacingOccurrences(of: #"\s*;\s*"#, with: "; ", options: .regularExpression)
                .replacingOccurrences(of: #";+\s*$"#, with: "", options: .regularExpression)
        }

        if input.contains("|") {
            let cleaned = input.replacingOccurrences(of: #"^BDUSS="#, with: "", options: [.regularExpression, .caseInsensitive])
            let parts = cleaned.components(separatedBy: "|")
            var cookie = "BDUSS=\(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))"
            if parts.count >= 2 {
                let stoken = parts[1]
                    .replacingOccurrences(of: #"^STOKEN="#, with: "", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !stoken.isEmpty {
                    cookie += "; STOKEN=\(stoken)"
                }
            }
            return cookie
        }

        return "BDUSS=\(input.replacingOccurrences(of: "BDUSS=", with: "").trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private func mergeCookieStrings(_ cookies: [String]) -> String {
        var orderedKeys: [String] = []
        var values: [String: (name: String, value: String)] = [:]

        for cookie in cookies where !cookie.isEmpty {
            for part in cookie.split(separator: ";") {
                let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = item.firstIndex(of: "=") else { continue }
                let name = String(item[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(item[item.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !value.isEmpty else { continue }
                let key = name.lowercased()
                if values[key] == nil {
                    orderedKeys.append(key)
                }
                values[key] = (name, value)
            }
        }

        return orderedKeys.compactMap { key in
            guard let item = values[key] else { return nil }
            return "\(item.name)=\(item.value)"
        }.joined(separator: "; ")
    }

    private var timeObserver: Any?
    private var statusObserver: AnyCancellable?
    private var failureObserver: AnyCancellable?
    private var endObserver: AnyCancellable?
    private var currentTask: Task<Void, Never>?
    
    func setupPlayer(video: VodItem) {
        currentTask?.cancel()
        currentVideo = video
        brightness = UIScreen.main.brightness
        volume = Double(AVAudioSession.sharedInstance().outputVolume)
        restorePlaybackProgress(for: video)
        loadDanmaku(for: video, fileName: video.vodName)
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await resolvePlayUrl(video: video)
        }
    }
    
    func cleanup() {
        currentTask?.cancel()
        currentTask = nil
        danmakuTask?.cancel()
        danmakuTask = nil
        savePlaybackProgress(force: true)
        quarkFallbackTimeoutTask?.cancel()
        quarkFallbackTimeoutTask = nil
        quarkFallbackURL = nil
        quarkFallbackHeaders = nil
        quarkFallbackSource = nil
        quarkFallbackAttempted = false
        baiduPrefetchTask?.cancel()
        baiduPrefetchTask = nil
        baiduPrefetchingIds.removeAll()
        baiduNearEndPrefetchedIndexes.removeAll()
        cleanupObservers()
        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player = nil
        compatibilityURL = nil
        compatibilityHeaders = [:]
    }
    
    // MARK: - 网盘视频处理
    private func handleCloudVideo(video: VodItem) async {
        log("[PlayerV2] 处理网盘视频...")
        
        // 检查 vodPlayUrl 是否是 JSON 格式的网盘链接列表
        if let playUrl = video.vodPlayUrl, playUrl.hasPrefix("[") {
            do {
                if let data = playUrl.data(using: .utf8),
                   let links = try JSONSerialization.jsonObject(with: data) as? [[String: String]] {
                    log("[PlayerV2] 解析到 \(links.count) 个网盘链接")
                    
                    // 尝试播放第一个有可用token的网盘链接
                    for link in links {
                        guard let url = link["url"], !url.isEmpty else { continue }
                        
                        if let driveType = CloudDriveManager.detectDrive(from: url) {
                            let tokens = CloudDriveManager.shared.tokens(for: driveType)
                            if !tokens.isEmpty {
                                log("[PlayerV2] 尝试播放 \(driveType.displayName)")
                                do {
                                    let result = try await CloudDriveManager.shared.resolvePlayURL(from: url)
                                    await playResolvedDriveVideo(result)
                                    return
                                } catch {
                                    log("[PlayerV2] \(driveType.displayName) 播放失败: \(error.localizedDescription)")
                                    continue
                                }
                            }
                        }
                    }
                    
                    await MainActor.run {
                        loadError = "网盘资源播放失败：请检查网盘Token配置"
                        isLoading = false
                    }
                    return
                }
            } catch {
                log("[PlayerV2] JSON解析失败: \(error)")
            }
        }
        
        // 检查 vodPlayUrl 是否是单个网盘链接
        if let playUrl = video.vodPlayUrl, !playUrl.isEmpty,
           let driveType = CloudDriveManager.detectDrive(from: playUrl) {
            log("[PlayerV2] 单个网盘链接: \(driveType.displayName)")
            await handleDriveUrl(playUrl, driveType: driveType)
            return
        }
        
        // 如果 vodId 是详情页URL，重新解析
        if video.vodId.hasPrefix("http") {
            log("[PlayerV2] 从详情页解析网盘链接...")
            if let result = await SpiderManager.shared.resolveCloudPlay(from: video.vodId), !result.links.isEmpty {
                log("[PlayerV2] 解析到 \(result.links.count) 个链接")
                
                for link in result.links {
                    if let driveType = CloudDriveManager.detectDrive(from: link.url) {
                        let tokens = CloudDriveManager.shared.tokens(for: driveType)
                        if !tokens.isEmpty {
                            do {
                                let playResult = try await CloudDriveManager.shared.resolvePlayURL(from: link.url)
                                await playResolvedDriveVideo(playResult)
                                return
                            } catch {
                                log("[PlayerV2] \(link.name) 失败: \(error.localizedDescription)")
                                continue
                            }
                        }
                    }
                }
            }
        }
        
        await MainActor.run {
            loadError = "网盘资源解析失败：未找到可播放链接"
            isLoading = false
        }
    }
    
    private func handleDriveUrl(_ urlString: String, driveType: CloudDriveManager.DriveType) async {
        let tokens = CloudDriveManager.shared.tokens(for: driveType)
        guard !tokens.isEmpty else {
            await MainActor.run {
                loadError = "未配置\(driveType.displayName) Token"
                isLoading = false
            }
            return
        }
        
        // 百度网盘：先获取文件列表，多文件则展示选择列表
        if driveType == .baidu {
            guard let pair = CloudDriveManager.shared.baiduTokenPair() else {
                await MainActor.run {
                    loadError = "缺少百度 Web Cookie：需要 BDUSS/STOKEN，PCS Cookie 不能替代"
                    isLoading = false
                }
                return
            }
            // 注册百度日志回调到悬浮日志
            CloudDriveManager.onLog = { [weak self] msg in
                self?.log("[PlayerV2] \(msg)")
            }
            log("[Baidu] ①请求分享页... WebToken=\(pair.web.name), PCSToken=\(pair.pcs?.name ?? "未配置")")
            do {
                let files = try await CloudDriveManager.shared.baiduGetFileList(shareURL: urlString, bduss: pair.web.value)
                log("[Baidu] ✅ 成功，共\(files.count)个文件: \(files.map { $0.name }.joined(separator: ", "))")
                await MainActor.run {
                    baiduFileList = files
                    baiduShareURL = urlString
                    baiduBduss = pair.web.value
                    baiduPcsCookie = pair.pcs?.value ?? ""
                }
                guard let firstFile = files.first else {
                    await MainActor.run {
                        loadError = "百度文件列表为空"
                        isLoading = false
                    }
                    return
                }

                let reason = files.count == 1 ? "自动播放单文件" : "自动播放"
                await startBaiduPlayback(
                    shareURL: urlString,
                    bduss: pair.web.value,
                    pcsCookie: pair.pcs?.value ?? "",
                    file: firstFile,
                    index: 0,
                    reason: reason
                )
                return
            } catch let error as DriveError {
                let specificMsg: String
                switch error {
                case .noPlayURL(let reason): specificMsg = reason
                case .invalidShareURL: specificMsg = "无效的分享链接"
                case .invalidResponse: specificMsg = "服务器响应异常"
                default: specificMsg = error.localizedDescription
                }
                log("[Baidu] ❌ ①出错: \(specificMsg)")
                await MainActor.run { loadError = specificMsg; isLoading = false }
                return
            } catch {
                log("[Baidu] ❌ ①出错: \(error.localizedDescription)")
                await MainActor.run { loadError = "百度解析失败: \(error.localizedDescription)"; isLoading = false }
                return
            }
        }
        
        do {
            let result = try await CloudDriveManager.shared.resolvePlayURL(from: urlString)
            await playResolvedDriveVideo(result)
        } catch let error as DriveError {
            let msg: String
            switch error {
            case .tokenNotConfigured: msg = "未配置\(driveType.displayName) Token"
            case .noPlayURL(let reason): msg = reason
            case .invalidShareURL: msg = "无效的分享链接"
            case .saveFailed: msg = "转存失败"
            case .invalidResponse: msg = "服务器响应异常"
            case .notImplemented: msg = "暂不支持"
            }
            log("[PlayerV2] ❌ \(driveType.displayName) 播放失败: \(msg)")
            await MainActor.run {
                loadError = msg
                isLoading = false
            }
        } catch {
            let msg = "解析异常: \(error.localizedDescription)"
            log("[PlayerV2] ❌ \(driveType.displayName) \(msg)")
            await MainActor.run {
                loadError = msg
                isLoading = false
            }
        }
    }
    
    private func playDriveVideo(url: String, headers: [String: String]) async {
        let playStartTime = Date()
        await MainActor.run {
            isLoading = true
            loadingMessage = "正在缓冲首帧..."
        }
        let finalURLString: String
        if url.contains("baidupcs.com") || url.contains("d.pcs.baidu.com") {
            if let localURL = DoubanImageProxyServer.shared.proxiedStreamURL(for: url, headers: headers, provider: "baidu") {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 百度PCS走本地代理: \(finalURLString)")
            } else {
                finalURLString = url
                log("[PlayerV2] ⚠️ 百度本地代理创建失败，回退直连")
            }
        } else if isQuarkM3U8PlaybackURL(url) {
            if let localURL = DoubanImageProxyServer.shared.proxiedQuarkM3U8URL(for: url, headers: headers) {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 夸克 m3u8 走本地代理: \(finalURLString)")
            } else {
                finalURLString = url
                log("[PlayerV2] ⚠️ 夸克 m3u8 本地代理创建失败，回退直连")
            }
        } else if isQuarkDirectPlaybackURL(url) {
            if let localURL = DoubanImageProxyServer.shared.proxiedStreamURL(for: url, headers: headers, provider: "quark") {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 夸克直链走本地代理: \(finalURLString)")
            } else {
                finalURLString = url
                log("[PlayerV2] ⚠️ 夸克本地代理创建失败，回退直连")
            }
        } else if isAliPlaybackURL(url) {
            if let localURL = DoubanImageProxyServer.shared.proxiedStreamURL(for: url, headers: headers, provider: "ali") {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 阿里云盘走本地代理: \(finalURLString)")
            } else {
                finalURLString = url
                log("[PlayerV2] ⚠️ 阿里云盘本地代理创建失败，回退直连")
            }
        } else if isUCPlaybackURL(url) {
            if let localURL = DoubanImageProxyServer.shared.proxiedStreamURL(for: url, headers: headers, provider: "uc") {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] UC网盘走本地代理: \(finalURLString)")
            } else {
                finalURLString = url
                log("[PlayerV2] ⚠️ UC本地代理创建失败，回退直连")
            }
        } else if is115PlaybackURL(url) {
            if let localURL = DoubanImageProxyServer.shared.proxiedStreamURL(for: url, headers: headers, provider: "115") {
                finalURLString = localURL.absoluteString
                log("[PlayerV2] 115网盘走本地代理: \(finalURLString)")
            } else {
                finalURLString = url
                log("[PlayerV2] ⚠️ 115本地代理创建失败，回退直连")
            }
        } else {
            finalURLString = url
        }

        guard let urlObj = createURL(from: finalURLString) else {
            await MainActor.run {
                loadError = "播放地址格式错误"
                isLoading = false
            }
            return
        }
        let isBaiduLocalProxy = urlObj.host == "127.0.0.1" && urlObj.path.contains("baidu-stream")
        let isQuarkLocalProxy = urlObj.host == "127.0.0.1" && urlObj.path.contains("quark-stream")
        let isQuarkM3U8LocalProxy = urlObj.host == "127.0.0.1" && urlObj.path.contains("quark-m3u8")
        let resourceName = currentPlaybackResourceName(fallbackURL: urlObj, originalURL: url)
        let playlistKind = await probeM3U8IfNeeded(url: urlObj, headers: headers)
        let isCloudLocalProxy = urlObj.host == "127.0.0.1"
            && (urlObj.path.contains("ali-stream") || urlObj.path.contains("uc-stream") || urlObj.path.contains("115-stream"))

        if isBaiduLocalProxy && enginePreference == .auto && isMPVBuildAvailable {
            await MainActor.run {
                playbackEngineMode = .compatibility
                compatibilityHint = "百度原画本地代理"
            }
            logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MPV-MoltenVK", reason: "baidu-stream 本地代理原画流")
            log("[Baidu] 自动模式下百度原画本地代理优先使用 MPV-MoltenVK，跳过系统内核 0x0 画面等待")
        } else if enginePreference == .auto, isM3U8URL(urlObj) || playlistKind != nil {
            await MainActor.run {
                playbackEngineMode = .system
                compatibilityHint = nil
            }
            let kind = playlistKind ?? .unknown
            let reason = kind == .fmp4 ? "#EXT-X-MAP/.m4s" : (kind == .ts ? "TS切片" : "m3u8未探测到fMP4特征")
            logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: kind, engine: "AVPlayer", reason: reason)
        } else if isQuarkLocalProxy && enginePreference == .auto && isVLCBuildAvailable && quarkFallbackURL == nil {
            await MainActor.run {
                playbackEngineMode = .compatibility
                compatibilityHint = "夸克网盘直链"
            }
            logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "VLC", reason: "quark-stream直链兼容")
            log("[Quark] 自动模式下夸克直链优先使用 VLC 兼容内核，减少 AVPlayer 首帧慢和 12847 兼容问题")
        } else if isQuarkLocalProxy && enginePreference == .auto && quarkFallbackURL != nil {
            await MainActor.run {
                playbackEngineMode = .system
                compatibilityHint = nil
            }
            logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "AVPlayer", reason: "夸克m3u8兜底可用")
            log("[Quark] 已启用 m3u8 兜底，原画主线路先用系统内核观察失败/超时")
        } else if enginePreference == .auto, shouldPreferMPVByResourceName(resourceName, url: urlObj), isMPVBuildAvailable {
            await MainActor.run {
                playbackEngineMode = .compatibility
                compatibilityHint = compatibilityReason(for: resourceName) ?? "复杂封装"
            }
            logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "MPV-MoltenVK", reason: "真实文件名/URL命中复杂封装")
        } else if enginePreference == .auto {
            logEngineResolver(resourceName: resourceName, url: urlObj, playlistKind: playlistKind, engine: "AVPlayer", reason: "默认系统内核")
        }

        if shouldUseCompatibilityEngine {
            let engineName = preferredCompatibilityEngineName(for: urlObj)
            log("[PlayerV2] 使用 \(engineName) 兼容内核播放：\(compatibilityHint ?? "特殊格式")")
            await MainActor.run {
                player?.pause()
                player = nil
                compatibilityEngineName = engineName
                compatibilityURL = urlObj
                compatibilityHeaders = urlObj.host == "127.0.0.1" ? [:] : headers
                isPlaying = true
                isLoading = false
            }
            return
        } else if playbackEngineMode == .compatibility {
            if enginePreference == .mpv {
                log("[PlayerV2] 已选择 MPV，但当前构建未包含 Libmpv，暂用系统内核尝试")
            } else {
                log("[PlayerV2] 资源需要兼容内核，但当前构建未包含可用兼容内核或已强制系统内核，暂用系统内核尝试")
            }
        }
        
        let assetHeaders = urlObj.host == "127.0.0.1" ? [:] : headers
        let asset = AVURLAsset(url: urlObj, options: ["AVURLAssetHTTPHeaderFieldsKey": assetHeaders])
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = urlObj.host == "127.0.0.1" ? 0.5 : 10.0

        var localStatusObserver: AnyCancellable?
        localStatusObserver = playerItem.publisher(for: \.status)
            .sink { [weak self] status in
                guard let self else { return }
                switch status {
                case .readyToPlay:
                    if isQuarkLocalProxy || isQuarkM3U8LocalProxy {
                        self.quarkFallbackTimeoutTask?.cancel()
                    }
                    let size = playerItem.presentationSize
                    let elapsed = Int(Date().timeIntervalSince(playStartTime) * 1000)
                    self.log("[PlayerV2] 网盘 PlayerItem 准备就绪，耗时=\(elapsed)ms，画面=\(Int(size.width))x\(Int(size.height))")
                    Task { @MainActor in
                        self.isLoading = false
                    }
                    self.scheduleVideoTrackCheck(
                        for: playerItem,
                        startedAt: playStartTime,
                        isBaiduLocalProxy: isBaiduLocalProxy,
                        fallbackURL: urlObj,
                        fallbackHeaders: assetHeaders
                    )
                case .failed:
                    let nsError = playerItem.error as? NSError
                    let errorDesc = playerItem.error?.localizedDescription ?? "未知错误"
                    self.log("[PlayerV2] ❌ 网盘 PlayerItem 失败: code=\(nsError?.code ?? -1) domain=\(nsError?.domain ?? "") desc=\(errorDesc)")
                    let underlyingDesc: String
                    if let underlying = nsError?.userInfo[NSUnderlyingErrorKey] as? Error {
                        underlyingDesc = underlying.localizedDescription
                        self.log("[PlayerV2] ❌ 网盘底层错误: \(underlyingDesc)")
                    } else {
                        underlyingDesc = ""
                    }

                    if isBaiduLocalProxy && self.isHTTPForbidden(errorDesc: errorDesc, underlyingDesc: underlyingDesc) {
                        self.log("[Baidu] ⚠️ 百度PCS流返回403，准备刷新直链后重试一次")
                        self.retryCurrentBaiduPlaybackAfterForbidden()
                        return
                    }
                    if isCloudLocalProxy && self.isHTTPForbidden(errorDesc: errorDesc, underlyingDesc: underlyingDesc) {
                        self.log("[PlayerV2] ⚠️ 网盘本地代理返回403，建议重新进入播放刷新直链")
                    }
                    if isQuarkLocalProxy && self.isHTTPForbidden(errorDesc: errorDesc, underlyingDesc: underlyingDesc) {
                        self.log("[Quark] ⚠️ 夸克本地代理返回403，后续需要重新刷新 download_url")
                        if self.switchToQuarkFallback(reason: "原画线路 403") { return }
                    }
                    // 夸克常见失败：NSURLErrorDomain code=-1 / "The network connection was lost"。
                    // 一般是上游签名失效或 UA/Cookie 不匹配被风控，提示用户重新进入触发刷新。
                    if isQuarkLocalProxy && self.isQuarkConnectionLost(error: nsError, errorDesc: errorDesc, underlyingDesc: underlyingDesc) {
                        self.log("[Quark] ⚠️ 夸克播放连接被中断 (network connection lost)，疑似签名/风控，建议返回重新播放刷新直链")
                        if self.switchToQuarkFallback(reason: "原画线路连接中断") { return }
                    }
                    if self.isUnsupportedMediaError(nsError, errorDesc: errorDesc, underlyingDesc: underlyingDesc) {
                        self.log("[PlayerV2] ⚠️ 当前资源疑似 AVPlayer 不支持，建议后续使用兼容内核")
                        if isQuarkLocalProxy {
                            if self.switchToQuarkFallback(reason: "系统内核不支持原画格式") { return }
                        } else {
                            Task { @MainActor in
                                self.loadError = "当前资源格式/编码不受系统播放器支持，建议使用兼容内核"
                                self.isLoading = false
                            }
                            return
                        }
                    }
                    Task { @MainActor in
                        self.loadError = "网盘播放失败: \(errorDesc)"
                        self.isLoading = false
                    }
                case .unknown:
                    self.log("[PlayerV2] 网盘 PlayerItem 状态未知")
                @unknown default:
                    break
                }
            }

        let localFailureObserver = NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .sink { [weak self] notification in
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    guard let self else { return }
                    self.log("[PlayerV2] ❌ 网盘播放中断: \(error.localizedDescription)")
                    if isBaiduLocalProxy && self.isHTTPForbidden(errorDesc: error.localizedDescription, underlyingDesc: "") {
                        self.log("[Baidu] ⚠️ 百度PCS播放中断疑似403，清理旧直链后重试一次")
                        self.retryCurrentBaiduPlaybackAfterForbidden()
                    } else if isQuarkLocalProxy && self.isHTTPForbidden(errorDesc: error.localizedDescription, underlyingDesc: "") {
                        self.log("[Quark] ⚠️ 夸克播放中断疑似403，准备切换 m3u8 兜底")
                        self.switchToQuarkFallback(reason: "原画播放中断 403")
                    } else if isQuarkLocalProxy && self.isQuarkConnectionLost(error: error as NSError, errorDesc: error.localizedDescription, underlyingDesc: "") {
                        self.log("[Quark] ⚠️ 夸克播放中断疑似连接丢失，准备切换 m3u8 兜底")
                        self.switchToQuarkFallback(reason: "原画播放中断")
                    }
                }
            }

        let p = AVPlayer(playerItem: playerItem)
        p.automaticallyWaitsToMinimizeStalling = !(isBaiduLocalProxy || isQuarkLocalProxy || isQuarkM3U8LocalProxy)
        if isQuarkLocalProxy {
            scheduleQuarkPrimaryFallbackTimeout(playerItem: playerItem, startedAt: playStartTime)
        } else if isQuarkM3U8LocalProxy {
            quarkFallbackTimeoutTask?.cancel()
        }
        
        await MainActor.run {
            if let observer = timeObserver { player?.removeTimeObserver(observer) }
            cleanupObservers()
            statusObserver = localStatusObserver
            failureObserver = localFailureObserver
            player?.pause()
            player = p
            isPlaying = true
            isLoading = true
            loadingMessage = "正在缓冲首帧..."
        }
        
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            if let d = p.currentItem?.duration {
                self.duration = d.seconds.isFinite ? d.seconds : 0
            }
            if isBaiduLocalProxy {
                self.prefetchNextBaiduFileNearEnd(current: self.currentTime, duration: self.duration)
            }
        }
        
        p.play()
    }

    private func prefetchNextBaiduFileNearEnd(current: Double, duration: Double) {
        guard duration.isFinite, duration > 0, current.isFinite, current > 0 else { return }
        guard currentEpisodeIndex + 1 < baiduFileList.count else { return }
        guard !baiduNearEndPrefetchedIndexes.contains(currentEpisodeIndex) else { return }

        let remaining = duration - current
        let threshold = duration >= 20 * 60 ? 180.0 : max(30.0, duration * 0.15)
        guard remaining <= threshold else { return }

        baiduNearEndPrefetchedIndexes.insert(currentEpisodeIndex)
        log("[Baidu-Preload] 当前集接近结尾，剩余\(Int(max(0, remaining)))秒，开始预取下一集")
        prefetchNextBaiduFile(after: currentEpisodeIndex)
    }

    private func isHTTPForbidden(errorDesc: String, underlyingDesc: String) -> Bool {
        let text = "\(errorDesc) \(underlyingDesc)".lowercased()
        return text.contains("403") || text.contains("forbidden")
    }

    private func currentPlaybackResourceName(fallbackURL: URL, originalURL: String) -> String {
        if currentEpisodeIndex >= 0, currentEpisodeIndex < baiduFileList.count {
            return baiduFileList[currentEpisodeIndex].name
        }
        if let decoded = fallbackURL.lastPathComponent.removingPercentEncoding, !decoded.isEmpty {
            return decoded
        }
        if let original = URL(string: originalURL)?.lastPathComponent.removingPercentEncoding, !original.isEmpty {
            return original
        }
        return fallbackURL.absoluteString
    }

    private func shouldPreferMPVByResourceName(_ resourceName: String, url: URL) -> Bool {
        let text = "\(resourceName) \(url.absoluteString)".lowercased()
        if text.contains(".mp4") || text.contains(".m3u8") || text.contains(".m4v") || text.contains(".mov") {
            return false
        }
        return text.contains(".mkv")
            || text.contains("mkv")
            || text.contains("hevc")
            || text.contains("h265")
            || text.contains("x265")
            || text.contains("10bit")
            || text.contains("hdr")
            || text.contains("4k")
    }

    private func isM3U8URL(_ url: URL) -> Bool {
        url.absoluteString.lowercased().contains(".m3u8") || url.path.lowercased().contains("m3u8")
    }

    private func logEngineResolver(resourceName: String, url: URL, playlistKind: M3U8PlaylistKind?, engine: String, reason: String) {
        let kindText = playlistKind?.rawValue ?? "none"
        log("[EngineResolver] resource=\(resourceName), kind=\(kindText), engine=\(engine), reason=\(reason), url=\(url.absoluteString.prefix(80))")
    }

    private func probeM3U8IfNeeded(url: URL, headers: [String: String]) async -> M3U8PlaylistKind? {
        guard isM3U8URL(url) else { return nil }
        let key = url.absoluteString
        if let cached = m3u8ProbeCache[key], cached.expiresAt > Date() {
            log("[EngineResolver] m3u8探测缓存命中：\(cached.kind.rawValue)")
            return cached.kind
        }

        do {
            let kind = try await probeM3U8Playlist(url: url, headers: headers)
            m3u8ProbeCache[key] = M3U8ProbeCacheEntry(kind: kind, expiresAt: Date().addingTimeInterval(5 * 60))
            log("[EngineResolver] m3u8探测完成：\(kind.rawValue)")
            return kind
        } catch {
            log("[EngineResolver] m3u8探测失败，默认系统内核：\(error.localizedDescription)")
            m3u8ProbeCache[key] = M3U8ProbeCacheEntry(kind: .unknown, expiresAt: Date().addingTimeInterval(60))
            return .unknown
        }
    }

    private func probeM3U8Playlist(url: URL, headers: [String: String]) async throws -> M3U8PlaylistKind {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.setValue("bytes=0-131071", forHTTPHeaderField: "Range")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, _) = try await URLSession.shared.data(for: request)
        let sample = String(data: data.prefix(131_072), encoding: .utf8)?.lowercased() ?? ""
        if sample.contains("#ext-x-map") || sample.contains(".m4s") {
            return .fmp4
        }
        if sample.contains(".ts") || sample.contains("mpegts") {
            return .ts
        }
        return .unknown
    }

    /// 判断是否是夸克侧常见的"连接被中断"。AVPlayer 在签名失效或 TLS 被风控关闭时通常返回
    /// NSURLErrorDomain code=-1（NSURLErrorUnknown）或 -1005（NSURLErrorNetworkConnectionLost），
    /// 描述里会带 "network connection was lost" / "未知错误"。
    private func isQuarkConnectionLost(error: NSError?, errorDesc: String, underlyingDesc: String) -> Bool {
        let text = "\(errorDesc) \(underlyingDesc)".lowercased()
        if let error, error.domain == NSURLErrorDomain {
            if [-1, -1005, NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost].contains(error.code) {
                return true
            }
        }
        return text.contains("network connection was lost")
            || text.contains("connection was lost")
            || text.contains("未知错误")
    }

    /// 夸克 download_url 实际跳转后域名波动较大（drive、dl、cdn、pcs、video 等多种 host）。
    /// 这里只要落在 *.quark.cn 且不属于 API/页面域，都认为是真实播放直链，需要走本地代理补 Header。
    private func isQuarkDirectPlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        guard host == "quark.cn" || host.hasSuffix(".quark.cn") else { return false }
        let excluded: Set<String> = [
            "pan.quark.cn",
            "drive-pc.quark.cn",
            "drive-h.quark.cn",
            "drive-m.quark.cn",
            "uop.quark.cn",
            "su.quark.cn",
            "www.quark.cn"
        ]
        return !excluded.contains(host)
    }

    private func isQuarkM3U8PlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        guard rawURL.lowercased().contains(".m3u8") else { return false }
        guard host == "quark.cn" || host.hasSuffix(".quark.cn") else { return false }
        let excluded: Set<String> = [
            "pan.quark.cn",
            "uop.quark.cn",
            "su.quark.cn",
            "www.quark.cn"
        ]
        return !excluded.contains(host)
    }

    private func isAliPlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        if host.contains("aliyundrive.com") || host.contains("alipan.com") || host.contains("aliyunpds.com") {
            return true
        }
        return host.hasSuffix(".aliyuncs.com") || host.contains("aliyun")
    }

    private func isUCPlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        if host == "uc.cn" || host.hasSuffix(".uc.cn") {
            let excluded: Set<String> = ["drive.uc.cn", "pc-api.uc.cn", "www.uc.cn"]
            return !excluded.contains(host)
        }
        return host.contains("ucdl") || host.contains("ucloud")
    }

    private func is115PlaybackURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let host = url.host?.lowercased() else { return false }
        return host == "115.com"
            || host.hasSuffix(".115.com")
            || host.contains("115cdn.com")
            || host.contains("anxia.com")
    }

    private func isUnsupportedMediaError(_ error: NSError?, errorDesc: String, underlyingDesc: String) -> Bool {
        let text = "\(errorDesc) \(underlyingDesc) \(error?.domain ?? "")".lowercased()
        if error?.domain == AVFoundationErrorDomain && [-11828, -11833].contains(error?.code ?? 0) {
            return true
        }
        return text.contains("-11828") || text.contains("-12847") || text.contains("无法打开") || text.contains("not open")
    }

    private func scheduleVideoTrackCheck(
        for item: AVPlayerItem,
        startedAt: Date,
        isBaiduLocalProxy: Bool,
        fallbackURL: URL,
        fallbackHeaders: [String: String]
    ) {
        guard isBaiduLocalProxy else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard self.player?.currentItem === item, self.loadError == nil else { return }
            let size = item.presentationSize
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            let seconds = self.player?.currentTime().seconds ?? 0
            self.log("[PlayerV2] 首帧检测：耗时=\(elapsed)ms，进度=\(String(format: "%.1f", seconds))s，画面=\(Int(size.width))x\(Int(size.height))")
            if seconds > 2, size.width <= 1 || size.height <= 1 {
                self.log("[PlayerV2] ⚠️ 有播放进度但画面尺寸为0，疑似视频轨/编码不兼容")
                self.switchAVPlayerVideoTrackFailureToMPV(url: fallbackURL, headers: fallbackHeaders)
            }
        }
    }

    private func switchAVPlayerVideoTrackFailureToMPV(url: URL, headers: [String: String]) {
        guard enginePreference != .system, isMPVBuildAvailable else {
            log("[PlayerV2] 当前构建/策略无法自动切 MPV，保留系统内核")
            return
        }

        log("[PlayerV2] 自动切换到 MPV-MoltenVK：系统内核有进度但无视频画面")
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        cleanupObservers()
        player?.pause()
        player = nil
        compatibilityEngineName = "MPV-MoltenVK"
        compatibilityURL = url
        compatibilityHeaders = headers
        playbackEngineMode = .compatibility
        compatibilityHint = "系统内核无视频画面"
        isPlaying = true
        isLoading = true
        loadingMessage = "正在切换 MPV-MoltenVK..."
    }

    private func retryCurrentBaiduPlaybackAfterForbidden() {
        guard baiduStreamRetryCount < 1 else {
            log("[Baidu] ❌ 百度PCS流403重试后仍失败，请更新PCS Cookie或重新扫码登录")
            Task { @MainActor in
                self.loadError = "百度PCS返回403：请更新PCS Cookie或重新扫码登录"
                self.isLoading = false
            }
            return
        }

        guard !baiduShareURL.isEmpty,
              currentEpisodeIndex >= 0,
              currentEpisodeIndex < baiduFileList.count
        else {
            log("[Baidu] ❌ 无法重试：缺少分享链接或当前集信息")
            return
        }

        baiduStreamRetryCount += 1
        let file = baiduFileList[currentEpisodeIndex]
        let index = currentEpisodeIndex
        CloudDriveManager.shared.invalidateBaiduPlaybackCache(
            shareURL: baiduShareURL,
            fsId: file.fsId,
            bduss: baiduBduss,
            pcsCookie: baiduPcsCookie,
            reason: "PCS403刷新直链重试"
        )
        log("[Baidu] ♻️ 已清理当前集旧 dlink/播放缓存，将优先用 path 刷新")
        currentTask?.cancel()
        currentTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await self.startBaiduPlayback(
                shareURL: self.baiduShareURL,
                bduss: self.baiduBduss,
                pcsCookie: self.baiduPcsCookie,
                file: file,
                index: index,
                reason: "PCS403刷新直链重试"
            )
        }
    }
    
    func retry(video: VodItem) {
        currentTask?.cancel()
        loadError = nil
        isLoading = true
        setupPlayer(video: video)
    }
    
    // MARK: - 播放地址解析
    private func resolvePlayUrl(video: VodItem) async {
        log("[PlayerV2] 开始解析播放地址: \(video.vodId)")
        
        // 检查是否是网盘资源（通过 vodRemarks 或 vodId 判断）
        if video.vodRemarks?.contains("网盘") == true || video.vodRemarks?.hasPrefix("☁️") == true {
            log("[PlayerV2] 检测到网盘资源，走网盘播放链路")
            await handleCloudVideo(video: video)
            return
        }
        
        // 如果 vodId 是 HTTP URL，可能是网盘详情页
        if video.vodId.hasPrefix("http://") || video.vodId.hasPrefix("https://") {
            // 检查是否包含网盘域名
            let panDomains = ["aliyundrive.com", "alipan.com", "pan.quark.cn", "pan.baidu.com", 
                              "115.com", "115cdn.com", "drive.uc.cn", "pan.uc.cn"]
            if panDomains.contains(where: { video.vodId.contains($0) }) {
                log("[PlayerV2] 检测到网盘URL，走网盘播放链路")
                await handleCloudVideo(video: video)
                return
            }
        }
        
        let spider = await SpiderManager.shared
        var playUrl: String? = video.vodPlayUrl
        var playFrom: String? = video.vodPlayFrom
        
        // 步骤1: 先用传入的播放地址尝试播放，同时后台获取详情
        log("[PlayerV2] 步骤1: 先尝试已有地址播放，后台异步获取详情...")
        
        // 先直接用已有地址尝试播放（如果有）
        if let existingUrl = video.vodPlayUrl, !existingUrl.isEmpty {
            let firstUrl = extractBestPlayableUrl(playFrom: video.vodPlayFrom ?? "", playUrl: existingUrl)
            let firstUrlClean = firstUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if !firstUrlClean.isEmpty {
                log("[PlayerV2] 步骤1: 先尝试已有地址: \(firstUrlClean.prefix(80))...")
                await handlePlayUrl(firstUrlClean, spider: spider, video: video)
            }
        }
        
        // 后台异步获取详情，成功后更新播放地址
        Task { [weak self] in
            guard let self = self else { return }
            log("[PlayerV2] 步骤1: 后台获取详情...")
            if let detail = await spider.getDetail(ids: video.vodId, name: video.vodName),
               let newUrl = detail.vodPlayUrl, !newUrl.isEmpty {
                log("[PlayerV2] 步骤1: 后台详情成功，检查是否需要更新")
                let newBest = extractBestPlayableUrl(playFrom: detail.vodPlayFrom ?? "", playUrl: newUrl)
                if !newBest.isEmpty {
                    await MainActor.run {
                        if self.player == nil || self.loadError != nil {
                            self.loadError = nil
                            Task { await self.handlePlayUrl(newBest, spider: spider, video: video) }
                        } else {
                            log("[PlayerV2] 步骤1: 已有播放器在运行，跳过更新")
                        }
                    }
                }
            } else {
                log("[PlayerV2] 步骤1: 后台详情无结果")
            }
        }
        
        // 如果已有地址不能播放，后面继续等后台详情更新
        if let existingUrl = video.vodPlayUrl, !existingUrl.isEmpty {
            log("[PlayerV2] 步骤1: 等待后台详情更新...")
            return
        }
        
        // 步骤2: 检查 playUrl 的类型并处理
        guard let finalPlayUrl = playUrl, !finalPlayUrl.isEmpty else {
            log("[PlayerV2] 错误: 没有可用的播放地址")
            await MainActor.run {
                loadError = "服务器未返回播放地址（详情页无视频源），请尝试其他资源或站点"
                isLoading = false
            }
            return
        }
        
        log("[PlayerV2] 步骤2: 处理播放地址")
        
        // 从 $$$ 多源格式中提取最佳 URL
        let bestUrl = extractBestPlayableUrl(playFrom: playFrom ?? "", playUrl: finalPlayUrl)
        log("[PlayerV2] 最佳URL: \(bestUrl.prefix(80))...")
        
        await handlePlayUrl(bestUrl, spider: spider, video: video)
    }
    
    // MARK: - 安全创建URL（处理编码）
    private func createURL(from urlString: String) -> URL? {
        // 先尝试直接创建
        if let url = URL(string: urlString) {
            return url
        }
        
        // 如果失败，尝试进行URL编码
        if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            if let url = URL(string: encoded) {
                log("[PlayerV2] URL编码成功: \(urlString.prefix(50))... -> \(encoded.prefix(50))...")
                return url
            }
        }
        
        // 尝试对路径部分编码
        if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) {
            if let url = URL(string: encoded) {
                log("[PlayerV2] URL编码成功(2): \(urlString.prefix(50))...")
                return url
            }
        }
        
        log("[PlayerV2] ❌ URL创建失败: \(urlString)")
        return nil
    }
    
    // MARK: - 处理单个播放地址
    private func handlePlayUrl(_ urlString: String, spider: SpiderManager, video: VodItem) async {
        log("[PlayerV2] 处理地址: \(urlString.prefix(80))...")
        
        // 检查是否是直链（通过URL后缀判断，支持带参数）
        let isDirectLink: Bool = {
            guard urlString.hasPrefix("http") else { return false }
            // 提取URL路径中的文件后缀（去掉查询参数）
            let cleanPath: String
            if let url = URL(string: urlString) {
                cleanPath = url.path
            } else if let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                      let url = URL(string: encoded) {
                cleanPath = url.path
            } else {
                cleanPath = urlString
            }
            let ext = (cleanPath as NSString).pathExtension.lowercased()
            let videoExts = ["m3u8", "mp4", "flv", "m4v", "ts", "webm", "mkv", "avi", "mov"]
            if videoExts.contains(ext) { return true }
            // 部分源不帶后缀但路径包含 /hls/ 或 /video/
            return cleanPath.contains("/hls/") || cleanPath.contains("/video/")
        }()
        
        if isDirectLink {
            log("[PlayerV2] 直链模式: 直接使用 URL=\(urlString.prefix(100))")
            if let url = createURL(from: urlString) {
                log("[PlayerV2] ✅ URL创建成功, 协议=\(url.scheme ?? "nil"), 主机=\(url.host ?? "nil")")
                await MainActor.run { initPlayer(url: url) }
                return
            }
            log("[PlayerV2] ❌ 直链URL创建失败, raw=\(urlString.prefix(120))")
        }
        
        // 需要解析的链接：先试解析器，再试 playerContent
        log("[PlayerV2] 解析模式: 非直链，尝试解析器")
        
        // 1. 优先用解析器（subManager.parses + customParsers）
        let allParsers = await MainActor.run { SpiderManager.shared.subManager.parses + SpiderManager.shared.customParsers }
        if !allParsers.isEmpty {
            log("[PlayerV2] 尝试 \(allParsers.count) 个解析器...")
            for parser in allParsers {
                let parseURL = parser.url + (urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString)
                guard let reqURL = URL(string: parseURL) else { continue }
                do {
                    var req = URLRequest(url: reqURL)
                    req.timeoutInterval = 8
                    req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                    let (data, _) = try await URLSession.shared.data(for: req)
                    if let resp = String(data: data, encoding: .utf8) {
                        // 从响应中提取 m3u8/mp4 链接
                        let patterns = ["https?://[^\\s\"<>]+\\.m3u8[^\\s\"<>]*", "https?://[^\\s\"<>]+\\.mp4[^\\s\"<>]*"]
                        for pattern in patterns {
                            if let regex = try? NSRegularExpression(pattern: pattern),
                               let match = regex.firstMatch(in: resp, range: NSRange(resp.startIndex..., in: resp)),
                               let r = Range(match.range, in: resp) {
                                let result = String(resp[r])
                                if result.hasPrefix("http"), let url = createURL(from: result) {
                                    log("[PlayerV2] ✅ 解析器[\(parser.name)]成功: \(result.prefix(60))")
                                    await MainActor.run { initPlayer(url: url) }
                                    return
                                }
                            }
                        }
                    }
                } catch { continue }
            }
        }
        
        // 2. 尝试 QuickJS playerContent
        if let pr = await spider.getPlayerContent(vodId: video.vodId, flag: "play", url: urlString) {
            let pu = pr.playUrl ?? pr.url
            if let pu = pu, !pu.isEmpty, let url = createURL(from: pu) {
                log("[PlayerV2] ✅ playerContent 成功: \(pu.prefix(60))")
                await MainActor.run { initPlayer(url: url) }
                return
            }
        }
        
        // 尝试 nativeDetail 作为备选
        log("[PlayerV2] 备选: 尝试 nativeDetail...")
        let nd = await spider.nativeDetail(ids: video.vodId, name: video.vodName)
        if let nd = nd, let pu = nd.vodPlayUrl, !pu.isEmpty {
            log("[PlayerV2] nativeDetail 成功")
            // 处理多集格式
            let urls = parsePlayUrls(playFrom: nd.vodPlayFrom ?? "", playUrl: pu)
            log("[PlayerV2] 解析出 \(urls.count) 个播放地址")
            for (index, videoUrl) in urls.enumerated() {
                log("[PlayerV2] 地址\(index): \(videoUrl.prefix(60))...")
            }
            let du = urls.first(where: { $0.contains(".m3u8") || $0.contains(".mp4") }) ?? urls.first ?? pu
            if !du.isEmpty {
                if let url = createURL(from: du) {
                    await MainActor.run { initPlayer(url: url) }
                    return
                }
                log("[PlayerV2] ❌ nativeDetail URL创建失败")
            }
        }
        
        // 检查是否是网盘链接
        log("[PlayerV2] 步骤5: 检查网盘链接...")
        let playUrlToCheck = video.vodPlayUrl ?? nd?.vodPlayUrl ?? urlString
        log("[PlayerV2] 待检测URL: \(playUrlToCheck.prefix(80))")
        if !playUrlToCheck.isEmpty, let driveType = CloudDriveManager.detectDrive(from: playUrlToCheck) {
            log("[PlayerV2] ✅ 检测到 \(driveType.displayName) 网盘链接")
            // 检查是否配置了Token
            let tokens = CloudDriveManager.shared.tokens(for: driveType)
            log("[PlayerV2] \(driveType.displayName) Token数量: \(tokens.count)")
            if tokens.isEmpty {
                let msg = "未配置\(driveType.displayName) Token，请到 设置→网盘播放 中添加"
                log("[PlayerV2] ❌ \(msg)")
                await MainActor.run { loadError = msg; isLoading = false }
                return
            }
            do {
                log("[PlayerV2] ⏳ 正在调用 \(driveType.displayName) API 解析...")
                let result = try await CloudDriveManager.shared.resolvePlayURL(from: playUrlToCheck)
                log("[PlayerV2] ✅ 网盘解析成功! 播放地址: \(result.url.prefix(80))...")
                log("[PlayerV2] 📋 请求头: \(result.headers.keys.joined(separator: ", "))")
                if URL(string: result.url) != nil {
                    await playResolvedDriveVideo(result)
                    return
                } else {
                    let msg = "\(driveType.displayName) 返回的播放地址无效: \(result.url.prefix(50))"
                    log("[PlayerV2] ❌ \(msg)")
                    await MainActor.run { loadError = msg; isLoading = false }
                    return
                }
            } catch let error as DriveError {
                let msg: String
                switch error {
                case .tokenNotConfigured(let name): msg = "未配置\(name) Token，请到 设置→网盘播放 中添加"
                case .noPlayURL(let reason): msg = "\(driveType.displayName) \(reason)"
                case .invalidShareURL: msg = "无效的\(driveType.displayName)分享链接"
                case .saveFailed: msg = "\(driveType.displayName) 转存失败"
                case .invalidResponse: msg = "\(driveType.displayName) 服务器响应异常"
                case .notImplemented: msg = "\(driveType.displayName) 暂不支持"
                }
                log("[PlayerV2] ❌ DriveError: \(msg)")
                await MainActor.run { loadError = msg; isLoading = false }
                return
            } catch {
                let msg = "\(driveType.displayName) 解析异常: \(error.localizedDescription)"
                log("[PlayerV2] ❌ \(msg)")
                await MainActor.run { loadError = msg; isLoading = false }
                return
            }
        } else {
            log("[PlayerV2] ⚠️ 未识别为网盘链接")
        }
        
        // 所有方式失败
        log("[PlayerV2] ❌ 所有方式都失败")
        await MainActor.run {
            cleanupObservers(); player?.pause()
            if let observer = timeObserver { player?.removeTimeObserver(observer); timeObserver = nil }
            player = nil
            loadError = "无法获取可用播放地址，请检查网络或更换其他资源"
            isLoading = false
        }
    }
    
    // MARK: - 从 $$$ 多源格式中提取最佳播放 URL
    private func extractBestPlayableUrl(playFrom: String, playUrl: String) -> String {
        // 不含 $$$ → 单源，按 # 和 $ 提取第一集
        if !playUrl.contains("$$$") {
            return extractFirstEpisodeUrl(playUrl)
        }
        
        // 含 $$$ → 多源，按 $$$ 分割
        let froms = playFrom.components(separatedBy: "$$$")
        let urlBlocks = playUrl.components(separatedBy: "$$$")
        
        // 为每个源提取第一集URL，按优先级排序：有 http 的 > 有 parse 可解析的 > 其他
        var candidates: [(source: String, url: String, hasHttp: Bool)] = []
        for i in 0..<min(froms.count, urlBlocks.count) {
            let src = froms[i]
            let firstUrl = extractFirstEpisodeUrl(urlBlocks[i])
            let hasHttp = firstUrl.hasPrefix("http")
            if !firstUrl.isEmpty {
                candidates.append((src, firstUrl, hasHttp))
                log("[PlayerV2] 源[\(i)] \(src): \(firstUrl.prefix(60))... http=\(hasHttp)")
            }
        }
        
        // 优先选有 http URL 的源
        if let best = candidates.first(where: { $0.hasHttp }) {
            log("[PlayerV2] 选择源: \(best.source) (http直链)")
            return best.url
        }
        
        // 没有 http 源，返回第一个
        if let first = candidates.first {
            log("[PlayerV2] 使用首个源: \(first.source)")
            return first.url
        }
        
        return playUrl
    }
    
    /// 从单个源块（如 "第1集$url1#第2集$url2"）提取第一集URL
    private func extractFirstEpisodeUrl(_ block: String) -> String {
        if block.contains("#") {
            // 取第一集
            let firstEp = block.components(separatedBy: "#").first ?? block
            if let range = firstEp.range(of: "$") {
                return String(firstEp[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            return firstEp.trimmingCharacters(in: .whitespaces)
        } else if block.contains("$") {
            if let range = block.range(of: "$") {
                return String(block[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return block.trimmingCharacters(in: .whitespaces)
    }
    
    // 保留旧方法供其他地方使用
    private func parsePlayUrls(playFrom: String, playUrl: String) -> [String] {
        var urls: [String] = []
        if playUrl.contains("#") {
            for part in playUrl.components(separatedBy: "#") {
                if let range = part.range(of: "$") {
                    let u = String(part[range.upperBound...])
                    if !u.isEmpty { urls.append(u) }
                } else if !part.isEmpty { urls.append(part) }
            }
        } else {
            urls = [playUrl]
        }
        return urls.filter { !$0.isEmpty }
    }
    
    private func initPlayer(url: URL) {
        log("[PlayerV2] 初始化播放器: \(url.absoluteString.prefix(100))...")

        if shouldRouteDirectURLToMPV(url) {
            log("[PlayerV2] 直链资源分流到 MPV-MoltenVK：\(url.pathExtension.lowercased())")
            player?.pause()
            player = nil
            compatibilityEngineName = "MPV-MoltenVK"
            compatibilityURL = url
            compatibilityHeaders = [:]
            playbackEngineMode = .compatibility
            compatibilityHint = "MKV / 复杂封装"
            isPlaying = true
            isLoading = true
            loadingMessage = "正在启动 MPV-MoltenVK..."
            return
        }
        
        // 清理旧的观察者（防止 retry 叠加）
        if let oldObserver = timeObserver {
            player?.removeTimeObserver(oldObserver)
            timeObserver = nil
        }
        cleanupObservers()
        player?.pause()
        player = nil
        
        // 配置Asset选项（针对m3u8切片优化）
        var assetOptions: [String: Any] = [:]
        
        // 提取域名作为Referer
        var referer = url.absoluteString
        if let host = url.host {
            referer = "https://\(host)/"
        }
        
        // 设置HTTP头（m3u8播放通常需要正确的User-Agent和Referer）
        assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1",
            "Accept": "*/*",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Referer": referer
        ]
        
        log("[PlayerV2] HTTP头配置 - Referer: \(referer)")
        
        // 创建Asset和PlayerItem
        let asset = AVURLAsset(url: url, options: assetOptions)
        let playerItem = AVPlayerItem(asset: asset)
        
        // 配置PlayerItem（针对HLS/m3u8优化）
        playerItem.preferredForwardBufferDuration = 10.0 // 预缓冲10秒

        // 创建播放器
        let p = AVPlayer(playerItem: playerItem)
        p.automaticallyWaitsToMinimizeStalling = true
        
        // 监听PlayerItem状态
        var localStatusObserver: AnyCancellable?
        localStatusObserver = playerItem.publisher(for: \.status)
            .sink { [weak self] status in
                guard let self = self else { return }
                switch status {
                case .readyToPlay:
                    self.log("[PlayerV2] PlayerItem 准备就绪")
                    if self.currentTime > 10 {
                        let resume = self.currentTime
                        self.log("[Progress] 自动跳转到上次进度：\(self.formatDuration(resume))")
                        p.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                case .failed:
                    let errorDesc = playerItem.error?.localizedDescription ?? "未知错误"
                    let errorCode = (playerItem.error as? NSError)?.code ?? -1
                    let errorDomain = (playerItem.error as? NSError)?.domain ?? ""
                    self.log("[PlayerV2] ❌ PlayerItem 失败: code=\(errorCode) domain=\(errorDomain) desc=\(errorDesc)")
                    if let underlying = (playerItem.error as? NSError)?.userInfo[NSUnderlyingErrorKey] as? Error {
                        self.log("[PlayerV2] ❌ 底层错误: \(underlying.localizedDescription)")
                    }
                    let errMsg = errorDesc.contains("不能") || errorDesc.contains("format") || errorDesc.contains("Invalid") 
                        ? "播放地址格式不支持" : "播放地址加载失败: \(errorDesc)"
                    Task { @MainActor in
                        self.loadError = errMsg
                        self.isLoading = false
                        self.player = nil
                    }
                case .unknown:
                    self.log("[PlayerV2] PlayerItem 状态未知")
                @unknown default:
                    break
                }
            }
        statusObserver = localStatusObserver
        
        // 监听播放失败
        failureObserver = NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime, object: playerItem)
            .sink { [weak self] notification in
                if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    self?.log("[PlayerV2] ❌ 播放失败: \(error.localizedDescription)")
                    Task { @MainActor in
                        self?.loadError = "播放失败: \(error.localizedDescription)"
                        self?.isLoading = false
                        self?.player = nil
                    }
                }
            }
        
        // 监听播放结束
        endObserver = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: playerItem)
            .sink { [weak self] _ in
                self?.log("[PlayerV2] 播放结束")
            }
        
        self.player = p
        self.isPlaying = true
        self.isLoading = false
        
        // 10秒超时保护：如果PlayerItem一直没就绪，显示错误
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self = self else { return }
            if await MainActor.run { self.player != nil && self.loadError == nil } {
                let status = await MainActor.run { p.currentItem?.status }
                if status != .readyToPlay {
                    await MainActor.run {
                        self.log("[PlayerV2] ⏱️ 播放地址加载超时")
                        self.loadError = "播放地址加载超时，请检查网络或更换资源"
                        self.isLoading = false
                    }
                }
            }
        }
        
        // 添加时间观察者
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: DispatchQueue.main) { [weak self] time in
            guard let self else { return }
            self.currentTime = time.seconds
            if let itemDuration = p.currentItem?.duration {
                self.duration = itemDuration.seconds.isFinite ? itemDuration.seconds : 0
            }
            self.updateDanmaku(at: time.seconds)
            self.savePlaybackProgress()
        }
        
        // 延迟播放确保UI准备好
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            p.play()
            self?.log("[PlayerV2] 播放器开始播放")
        }
    }

    private func shouldRouteDirectURLToMPV(_ url: URL) -> Bool {
        guard enginePreference != .system, isMPVBuildAvailable else { return false }
        if enginePreference == .mpv { return true }
        let text = url.absoluteString.lowercased()
        let ext = url.pathExtension.lowercased()
        if ext == "mp4" || ext == "m4v" || ext == "mov" { return false }
        if ext == "m3u8" { return false }
        return ext == "mkv" || text.contains(".mkv") || text.contains("mkv")
    }
    
    private func cleanupObservers() {
        statusObserver?.cancel()
        failureObserver?.cancel()
        endObserver?.cancel()
        statusObserver = nil
        failureObserver = nil
        endObserver = nil
    }
}

// MARK: - 播放器容器视图
struct PlayerContainerView: View {
    let player: AVPlayer?
    @ObservedObject var playerState: PlayerState
    let video: VodItem
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            // 视频层（如果有播放器）
            if let url = playerState.compatibilityURL {
                if playerState.compatibilityEngineName.contains("MPV") {
                    #if canImport(Libmpv)
                    LibmpvMoltenVKPlayerRepresentableV2(url: url, headers: playerState.compatibilityHeaders, playerState: playerState)
                        .ignoresSafeArea()
                    #else
                    CompatibilityUnavailableView(engineName: "MPV-MoltenVK", message: "当前构建未包含 Libmpv")
                    #endif
                } else {
                #if canImport(MobileVLCKit)
                VLCPlayerRepresentableV2(url: url, headers: playerState.compatibilityHeaders, playerState: playerState)
                    .ignoresSafeArea()
                #else
                CompatibilityUnavailableView(engineName: "VLC", message: "当前构建未包含 VLC，请等待兼容内核构建包")
                #endif
                }
            } else if let player = player {
                AVPlayerControllerRepresentableV2(player: player)
                    .ignoresSafeArea()
            }
            
            // 加载层：播放器初始化后到首帧出现前也持续显示，避免黑屏无反馈
            if playerState.isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text(playerState.loadingMessage)
                        .foregroundColor(.white.opacity(0.8))
                        .font(.subheadline)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .background(Color.black.opacity(0.45))
                .cornerRadius(14)
            }
            
            // 弹幕层
            if playerState.showDanmaku {
                DanmakuOverlayViewV2(
                    showDanmaku: $playerState.showDanmaku,
                    opacity: playerState.danmakuOpacity,
                    fontSize: playerState.danmakuFontSize,
                    currentTime: playerState.currentTime,
                    items: playerState.danmakuItems
                )
                .allowsHitTesting(false)
            }
            
            // 手势层
            GestureControlView(playerState: playerState) {
                guard !playerState.isSeeking else { return }
                guard !playerState.showSettings,
                      !playerState.showEpisodePicker,
                      !playerState.showQualityPicker,
                      !playerState.showDanmakuSettings,
                      !playerState.showEnginePicker else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    playerState.showControls.toggle()
                }
            }
            .ignoresSafeArea()
            
            // 控制层 - 始终显示，只是控制栏可以隐藏/显示
            if playerState.showControls {
                PlayerControlsView(
                    player: player,
                    playerState: playerState,
                    video: video
                )
            }
        }
    }
}

// MARK: - 错误视图
struct ErrorView: View {
    let error: String
    let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 50))
                    .foregroundColor(.orange)
                Text("加载失败")
                    .foregroundColor(.white)
                    .font(.title2)
                Text(error)
                    .foregroundColor(.white.opacity(0.7))
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                HStack(spacing: 20) {
                    Button(action: onRetry) {
                        Text("重试")
                            .foregroundColor(.white)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                    
                    Button(action: { dismiss() }) {
                        Text("返回")
                            .foregroundColor(.white)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 12)
                            .background(Color.gray)
                            .cornerRadius(8)
                    }
                }
            }
            Spacer()
        }
    }
}

// MARK: - 错误视图（简洁版，日志在绿色浮层里看）
struct ErrorViewWithLogs: View {
    let error: String
    let logs: [String]
    let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 50))
                    .foregroundColor(.orange)
                Text("加载失败")
                    .foregroundColor(.white)
                    .font(.title2)
                Text(error)
                    .foregroundColor(.white.opacity(0.9))
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                HStack(spacing: 20) {
                    Button(action: onRetry) {
                        Text("重试").foregroundColor(.white)
                            .padding(.horizontal, 40).padding(.vertical, 12)
                            .background(Color.blue).cornerRadius(8)
                    }
                    Button(action: { dismiss() }) {
                        Text("返回").foregroundColor(.white)
                            .padding(.horizontal, 40).padding(.vertical, 12)
                            .background(Color.gray).cornerRadius(8)
                    }
                }
            }
            Spacer()
        }
    }
}

// MARK: - 播放器控制视图
struct PlayerControlsView: View {
    let player: AVPlayer?
    @ObservedObject var playerState: PlayerState
    let video: VodItem
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack {
            // 顶部返回栏
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.3))
                        .clipShape(Circle())
                }
                
                Spacer()
                
                // 屏幕锁定按钮
                Button(action: { 
                    playerState.isOrientationLocked.toggle()
                    if playerState.isOrientationLocked {
                        OrientationHelper.lockOrientation(.landscape)
                    } else {
                        OrientationHelper.unlockOrientation()
                    }
                }) {
                    Image(systemName: playerState.isOrientationLocked ? "lock.fill" : "lock.open")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.3))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            
            Spacer()
            
            // 底部控制栏
            VStack(spacing: 0) {
                // 进度条区域
                HStack(spacing: 12) {
                    Text(formatTime(playerState.isSeeking ? playerState.seekPreviewTime : playerState.currentTime))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                    
                    GeometryReader { geometry in
                        let displayTime = playerState.isSeeking ? playerState.seekPreviewTime : playerState.currentTime
                        let progress = playerState.duration > 0 ? max(0, min(displayTime / playerState.duration, 1)) : 0
                        ZStack(alignment: .leading) {
                            // 背景轨道
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.3))
                                .frame(height: 4)
                            
                            // 进度条
                            if playerState.duration > 0 {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(hex: "00BEFF"))
                                    .frame(width: CGFloat(progress) * geometry.size.width, height: 4)
                                Circle()
                                    .fill(Color(hex: "00BEFF"))
                                    .frame(width: 14, height: 14)
                                    .offset(x: max(0, min(CGFloat(progress) * geometry.size.width - 7, geometry.size.width - 14)))
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard playerState.duration > 0 else { return }
                                    let x = max(0, min(value.location.x, geometry.size.width))
                                    let target = Double(x / geometry.size.width) * playerState.duration
                                    playerState.isSeeking = true
                                    playerState.seekPreviewTime = target
                                }
                                .onEnded { value in
                                    guard playerState.duration > 0 else { return }
                                    let x = max(0, min(value.location.x, geometry.size.width))
                                    let target = Double(x / geometry.size.width) * playerState.duration
                                    playerState.seek(to: target)
                                }
                        )
                    }
                    .frame(height: 20)
                    
                    Text(formatTime(playerState.duration))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                
                // 按钮控制栏
                HStack(spacing: 20) {
                    // 播放/暂停：系统内核和 VLC 兼容内核都可用
                    Button(action: {
                        playerState.togglePlayback(player: player)
                    }) {
                        Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22))
                            .foregroundColor((player == nil && playerState.compatibilityURL == nil) ? .gray : .white)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(player == nil && playerState.compatibilityURL == nil)
                    
                    // 下一个（如果是多集）
                    Button(action: { playerState.playNextBaiduFile() }) {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 20))
                            .foregroundColor(playerState.currentEpisodeIndex + 1 < playerState.baiduFileList.count ? .white : .gray)
                            .frame(width: 44, height: 44)
                    }
                    .disabled(playerState.currentEpisodeIndex + 1 >= playerState.baiduFileList.count)
                    
                    Spacer()
                    
                    // 选集
                    Button(action: { playerState.showEpisodePicker = true }) {
                        VStack(spacing: 2) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 18))
                            Text("选集")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                    }
                    
                    // 清晰度
                    Button(action: { playerState.showQualityPicker = true }) {
                        Text(playerState.baiduFileList.isEmpty ? "高清" : "原画")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.white.opacity(0.5), lineWidth: 1)
                            )
                    }
                    
                    // AirPlay
                    AirPlayViewV2()
                        .frame(width: 44, height: 44)
                    
                    // 播放内核
                    Button(action: { playerState.showEnginePicker = true }) {
                        VStack(spacing: 2) {
                            Image(systemName: "cpu")
                                .font(.system(size: 18))
                            Text(playerState.currentEngineButtonTitle)
                                .font(.system(size: 9))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .foregroundColor(playerState.playbackEngineMode == .compatibility ? Color(hex: "00BEFF") : .white)
                        .frame(width: 56, height: 44)
                    }

                    // 弹幕
                    Button(action: { playerState.showDanmakuSettings = true }) {
                        VStack(spacing: 2) {
                            Image(systemName: "text.bubble")
                                .font(.system(size: 18))
                            Text("弹幕")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(playerState.showDanmaku ? Color(hex: "00BEFF") : .white)
                        .frame(width: 44, height: 44)
                    }
                    
                    // 更多设置
                    Button(action: { playerState.showSettings = true }) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.black.opacity(0),
                        Color.black.opacity(0.6),
                        Color.black.opacity(0.8)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        // 侧边栏弹窗 - 播放设置
        .overlay(
            SidePanelView(isPresented: $playerState.showSettings, title: "播放设置") {
                PlayerSettingsPanelV2(speed: $playerState.playbackSpeed, onSpeedChange: { speed in
                    playerState.changePlaybackSpeed(speed)
                })
            }
        )
        // 侧边栏弹窗 - 选集
        .overlay(
            SidePanelView(isPresented: $playerState.showEpisodePicker, title: "选集") {
                EpisodePickerPanelV2(playerState: playerState)
            }
        )
        // 侧边栏弹窗 - 清晰度
        .overlay(
            SidePanelView(isPresented: $playerState.showQualityPicker, title: "清晰度") {
                QualityPickerPanelV2(
                    selectedQuality: $playerState.selectedQuality,
                    isBaiduSourceMode: !playerState.baiduFileList.isEmpty,
                    onQualityChange: { index in
                        playerState.changeQuality(index: index)
                    }
                )
            }
        )
        // 侧边栏弹窗 - 弹幕设置
        .overlay(
            SidePanelView(isPresented: $playerState.showDanmakuSettings, title: "弹幕设置") {
                DanmakuSettingsPanelV2(
                    showDanmaku: $playerState.showDanmaku,
                    opacity: $playerState.danmakuOpacity,
                    fontSize: $playerState.danmakuFontSize
                )
            }
        )
        // 侧边栏弹窗 - 播放内核
        .overlay(
            SidePanelView(isPresented: $playerState.showEnginePicker, title: "播放内核") {
                EnginePickerPanelV2(playerState: playerState)
            }
        )
    }
    
    private func formatTime(_ time: Double) -> String {
        let hours = Int(time) / 3600
        let minutes = (Int(time) % 3600) / 60
        let seconds = Int(time) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

// MARK: - AVPlayer 控制器封装 V2
struct AVPlayerControllerRepresentableV2: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspectFill
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

struct CompatibilityUnavailableView: View {
    let engineName: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "play.slash")
                .font(.system(size: 42))
                .foregroundColor(.white.opacity(0.85))
            Text("当前资源需要\(engineName)兼容内核")
                .foregroundColor(.white)
                .font(.headline)
            Text(message)
                .foregroundColor(.white.opacity(0.7))
                .font(.subheadline)
        }
    }
}

#if canImport(Libmpv)
// MARK: - Libmpv-MoltenVK 正式播放层 V2
struct LibmpvMoltenVKPlayerRepresentableV2: UIViewRepresentable {
    let url: URL
    let headers: [String: String]
    @ObservedObject var playerState: PlayerState

    func makeCoordinator() -> Coordinator {
        Coordinator(playerState: playerState)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        context.coordinator.attach(to: view, url: url, headers: headers)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.attach(to: uiView, url: url, headers: headers)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        private let core = LibmpvMoltenVKPlayerCore()
        private var observers: [NSObjectProtocol] = []
        private weak var playerState: PlayerState?
        private var isStopped = false
        var currentURL: URL?

        init(playerState: PlayerState) {
            self.playerState = playerState
            core.onLog = { [weak playerState] message in
                guard playerState?.compatibilityURL != nil else { return }
                playerState?.log("[MPV-MoltenVK] \(message)")
            }
            core.onStateChange = { [weak playerState] state in
                guard let playerState else { return }
                guard playerState.compatibilityURL != nil else { return }
                playerState.currentTime = state.currentTime
                if state.duration.isFinite, state.duration > 0 {
                    playerState.duration = state.duration
                }
                playerState.updateDanmaku(at: state.currentTime)
                playerState.savePlaybackProgress()
                playerState.isLoading = state.isBuffering
                playerState.isPlaying = state.isPlaying
                if let error = state.errorMessage {
                    playerState.loadError = error
                }
            }

            observers.append(NotificationCenter.default.addObserver(forName: .vboxMPVPlay, object: nil, queue: .main) { [weak self] _ in
                self?.core.play()
            })
            observers.append(NotificationCenter.default.addObserver(forName: .vboxMPVPause, object: nil, queue: .main) { [weak self] _ in
                self?.core.pause()
            })
            observers.append(NotificationCenter.default.addObserver(forName: .vboxMPVSeek, object: nil, queue: .main) { [weak self] note in
                guard let seconds = note.userInfo?["seconds"] as? Double else { return }
                self?.core.seek(to: seconds)
            })
            observers.append(NotificationCenter.default.addObserver(forName: .vboxMPVSpeed, object: nil, queue: .main) { [weak self] note in
                guard let speed = note.userInfo?["speed"] as? Double else { return }
                self?.core.setRate(speed)
            })
        }

        deinit {
            stop()
        }

        func attach(to view: UIView, url: URL, headers: [String: String]) {
            guard !isStopped else { return }
            currentURL = url
            core.attach(to: view)
            core.load(url: url, headers: headers, profile: inferredProfile(for: url))
            core.setRate(playerState?.playbackSpeed ?? 1.0)
            core.play()
            if let resume = playerState?.currentTime, resume > 10 {
                core.seek(to: resume)
                playerState?.log("[Progress] MPV 自动跳转到上次进度：\(Int(resume))s")
            }
            playerState?.isLoading = true
            playerState?.loadingMessage = "正在启动 MPV-MoltenVK..."
        }

        func stop() {
            guard !isStopped else { return }
            isStopped = true
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            core.onLog = nil
            core.onStateChange = nil
            core.stop()
            core.teardown()
            currentURL = nil
            playerState = nil
        }

        private func inferredProfile(for url: URL) -> LibmpvMoltenVKPlayerCore.PlaybackProfile {
            let text = url.absoluteString.lowercased()
            let ext = url.pathExtension.lowercased()
            if ext == "mkv" || text.contains("mkv") { return .mkvLarge }
            if ext == "m3u8" { return .hlsFast }
            if ext == "mp4" || ext == "m4v" || ext == "mov" { return .mp4 }
            return .generic
        }
    }
}
#endif

#if canImport(MobileVLCKit)
// MARK: - VLC 兼容播放内核封装 V2
struct VLCPlayerRepresentableV2: UIViewRepresentable {
    let url: URL
    let headers: [String: String]
    @ObservedObject var playerState: PlayerState

    func makeCoordinator() -> VLCPlayerCoordinatorV2 {
        VLCPlayerCoordinatorV2(playerState: playerState)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        context.coordinator.attach(to: view, url: url, headers: headers)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.attach(to: uiView, url: url, headers: headers)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: VLCPlayerCoordinatorV2) {
        coordinator.stop()
    }

    final class VLCPlayerCoordinatorV2 {
        private let mediaPlayer = VLCMediaPlayer()
        private var observers: [NSObjectProtocol] = []
        private var progressTimer: Timer?
        private weak var playerState: PlayerState?
        private var didFinish = false
        var currentURL: URL?

        init(playerState: PlayerState) {
            self.playerState = playerState
            observers.append(
                NotificationCenter.default.addObserver(forName: .vboxVLCPlay, object: nil, queue: .main) { [weak self] _ in
                    self?.mediaPlayer.play()
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(forName: .vboxVLCPause, object: nil, queue: .main) { [weak self] _ in
                    self?.mediaPlayer.pause()
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(forName: .vboxVLCSeek, object: nil, queue: .main) { [weak self] note in
                    guard let seconds = note.userInfo?["seconds"] as? Double else { return }
                    self?.seek(to: seconds)
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(forName: .vboxVLCSpeed, object: nil, queue: .main) { [weak self] note in
                    guard let speed = note.userInfo?["speed"] as? Double else { return }
                    self?.mediaPlayer.rate = Float(speed)
                }
            )
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            progressTimer?.invalidate()
        }

        func attach(to view: UIView, url: URL, headers: [String: String]) {
            currentURL = url
            mediaPlayer.drawable = view
            let media = VLCMedia(url: url)
            var options: [AnyHashable: Any] = [:]
            if let ua = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
                options["http-user-agent"] = ua
            }
            if let referer = headers.first(where: { $0.key.lowercased() == "referer" })?.value {
                options["http-referrer"] = referer
            }
            if !options.isEmpty {
                media.addOptions(options)
            }
            mediaPlayer.media = media
            mediaPlayer.play()
            mediaPlayer.rate = Float(playerState?.playbackSpeed ?? 1.0)
            didFinish = false
            startProgressTimer()
        }

        func stop() {
            progressTimer?.invalidate()
            progressTimer = nil
            mediaPlayer.stop()
            mediaPlayer.drawable = nil
            currentURL = nil
        }

        private func seek(to seconds: Double) {
            let duration = Double(mediaPlayer.media?.length.intValue ?? 0) / 1000.0
            guard duration.isFinite, duration > 0 else { return }
            mediaPlayer.position = Float(max(0, min(seconds / duration, 1)))
        }

        private func startProgressTimer() {
            progressTimer?.invalidate()
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                let current = Double(self.mediaPlayer.time.intValue) / 1000.0
                let total = Double(self.mediaPlayer.media?.length.intValue ?? 0) / 1000.0
                guard current.isFinite, total.isFinite, total > 0 else { return }

                self.playerState?.currentTime = max(0, current)
                self.playerState?.duration = max(0, total)

                if !self.didFinish, current >= max(0, total - 0.8), total > 1 {
                    self.didFinish = true
                    self.playerState?.isPlaying = false
                    self.playerState?.currentTime = total
                    self.playerState?.log("[PlayerV2] VLC 播放结束")
                }
            }
        }
    }
}
#endif

// MARK: - 弹幕设置视图
struct DanmakuSettingsViewV2: View {
    @Binding var showDanmaku: Bool
    @Binding var opacity: Double
    @Binding var fontSize: CGFloat

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("弹幕开关") {
                    Toggle("开启弹幕", isOn: $showDanmaku)
                }

                Section("弹幕透明度") {
                    Slider(value: $opacity, in: 0...1, step: 0.1)
                }

                Section("弹幕字体大小") {
                    Slider(value: $fontSize, in: 12...24, step: 2)
                }
            }
            .navigationTitle("弹幕设置")
        }
    }
}

// MARK: - 弹幕数据模型
private struct DanmakuItemData: Identifiable {
    let text: String
    var x: CGFloat
    let y: CGFloat
    let id: Int
}

// MARK: - 弹幕覆盖层

// MARK: - AirPlay 视图

// MARK: - 播放设置视图
struct PlayerSettingsViewV2: View {
    @Binding var speed: Double
    var onSpeedChange: (Double) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("播放速度") {
                    ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { s in
                        Button("\(s)x") {
                            speed = s
                            onSpeedChange(s)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("播放设置")
        }
    }
}

// MARK: - 选集选择视图
struct EpisodePickerViewV2: View {
    let video: VodItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(1..<21, id: \.self) { ep in
                    Button("第\(ep)集") {
                        dismiss()
                    }
                }
            }
            .navigationTitle("选集")
        }
    }
}

// MARK: - 清晰度选择视图
struct QualityPickerViewV2: View {
    @Binding var selectedQuality: Int
    var onQualityChange: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(0..<3, id: \.self) { index in
                    Button(["标清", "高清", "蓝光"][index]) {
                        selectedQuality = index
                        onQualityChange(index)
                        dismiss()
                    }
                }
            }
            .navigationTitle("清晰度")
        }
    }
}

// MARK: - 侧边栏弹窗容器
struct SidePanelView<Content: View>: View {
    @Binding var isPresented: Bool
    let title: String
    let content: Content
    
    init(isPresented: Binding<Bool>, title: String, @ViewBuilder content: () -> Content) {
        self._isPresented = isPresented
        self.title = title
        self.content = content()
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isPresented {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isPresented = false
                            }
                        }
                    
                    HStack {
                        Spacer()
                        
                        VStack(spacing: 0) {
                            HStack {
                                Text(title)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                                
                                Spacer()
                                
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        isPresented = false
                                    }
                                }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundColor(.white)
                                        .frame(width: 36, height: 36)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .background(Color.black.opacity(0.9))
                            
                            content
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(hex: "1A1A1A"))
                        }
                        .frame(width: geometry.size.width * 0.45)
                        .background(Color(hex: "1A1A1A"))
                        .cornerRadius(12, corners: [.topLeft, .bottomLeft])
                        .transition(.move(edge: .trailing))
                    }
                    .ignoresSafeArea()
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isPresented)
        }
    }
}

// MARK: - 播放设置面板 (侧边栏版本)
struct PlayerSettingsPanelV2: View {
    @Binding var speed: Double
    var onSpeedChange: (Double) -> Void
    
    let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("播放速度")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(speeds, id: \.self) { s in
                        Button(action: {
                            speed = s
                            onSpeedChange(s)
                        }) {
                            let speedText = s == floor(s) ? String(format: "%.0f", s) : String(format: "%.2f", s)
                            Text(speedText + "X")
                                .font(.system(size: 16, weight: speed == s ? .semibold : .regular))
                                .foregroundColor(speed == s ? Color(hex: "00BEFF") : .white)
                                .frame(maxWidth: .infinity, minHeight: 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(speed == s ? Color(hex: "00BEFF").opacity(0.2) : Color.white.opacity(0.1))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(speed == s ? Color(hex: "00BEFF") : Color.clear, lineWidth: 1)
                                )
                        }
                    }
                }
                .padding(.horizontal, 16)
                
                Spacer()
            }
        }
    }
}

// MARK: - 选集面板 (侧边栏版本)

// MARK: - 清晰度面板 (侧边栏版本)
struct QualityPickerPanelV2: View {
    @Binding var selectedQuality: Int
    var isBaiduSourceMode: Bool = false
    var onQualityChange: (Int) -> Void
    
    private var qualities: [String] {
        isBaiduSourceMode ? ["原画"] : ["标清", "高清", "蓝光"]
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if isBaiduSourceMode {
                    Text("百度DLNA当前播放源文件链路，清晰度由资源本身决定。后续接入转码/兼容内核后再支持多清晰度切换。")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.65))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
                ForEach(0..<qualities.count, id: \.self) { index in
                    Button(action: {
                        selectedQuality = index
                        onQualityChange(index)
                    }) {
                        HStack {
                            Text(qualities[index])
                                .font(.system(size: 16, weight: selectedQuality == index ? .semibold : .regular))
                                .foregroundColor(selectedQuality == index ? Color(hex: "00BEFF") : .white)
                            
                            Spacer()
                            
                            if selectedQuality == index {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(hex: "00BEFF"))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedQuality == index ? Color(hex: "00BEFF").opacity(0.1) : Color.clear)
                        )
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - 播放内核面板 (侧边栏版本)
struct EnginePickerPanelV2: View {
    @ObservedObject var playerState: PlayerState

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("内核选择只影响后续起播/重载当前集。后面重做控制栏排序和弹窗样式时，可以直接替换这个面板，不影响底层播放逻辑。")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.65))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                ForEach(PlayerState.PlaybackEnginePreference.allCases) { engine in
                    Button(action: {
                        playerState.selectPlaybackEngine(engine)
                    }) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(engine.rawValue)
                                    .font(.system(size: 16, weight: playerState.enginePreference == engine ? .semibold : .regular))
                                    .foregroundColor(playerState.enginePreference == engine ? Color(hex: "00BEFF") : .white)
                                Text(engine.subtitle)
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.55))
                                    .multilineTextAlignment(.leading)
                            }

                            Spacer()

                            if playerState.enginePreference == engine {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(Color(hex: "00BEFF"))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(playerState.enginePreference == engine ? Color(hex: "00BEFF").opacity(0.1) : Color.clear)
                        )
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - 弹幕设置面板 (侧边栏版本)
struct DanmakuSettingsPanelV2: View {
    @Binding var showDanmaku: Bool
    @Binding var opacity: Double
    @Binding var fontSize: CGFloat
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack {
                    Text("开启弹幕")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Toggle("弹幕", isOn: $showDanmaku)
                        .labelsHidden()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                
                VStack(spacing: 8) {
                    HStack {
                        Text("弹幕透明度")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(Int(opacity * 100))%")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 16)
                    
                    Slider(value: $opacity, in: 0...1, step: 0.1)
                        .padding(.horizontal, 16)
                }
                
                VStack(spacing: 8) {
                    HStack {
                        Text("弹幕字体大小")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(Int(fontSize))px")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(.horizontal, 16)
                    
                    Slider(value: $fontSize, in: 12...24, step: 1)
                        .padding(.horizontal, 16)
                }
                
                Spacer()
            }
        }
    }
}

// MARK: - View Extension for Corner Radius
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    
    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
