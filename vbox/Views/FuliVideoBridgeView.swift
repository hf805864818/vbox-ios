import SwiftUI

// MARK: - 线路分组（UI 层概念）
// 从扁平 episodes 数组中检测 [线路名] 前缀，自动分组为线路 + 集数两层。
// WelfareResultMapper 在多线路时会给集名加 [线路名] 前缀，这里负责拆分还原。
struct FuliLine: Identifiable {
    var id: String { name }
    let name: String
    let episodes: [FuliEpisode]
}

// MARK: - 福利平台播放中转页
// 点击视频卡片后直接进入此页，解析播放地址后调用项目现有播放器 VideoPlayerViewV2
// 不经过 VideoDetailView，不影响网盘/切片/短剧等既有播放链路
struct FuliVideoBridgeView<Service: FuliPlatformService>: View {
    @ObservedObject var svc: Service
    let video: FuliVideo

    @State private var detail: FuliDetail?
    @State private var isLoading = true
    @State private var errorMsg: String?
    @State private var showPlayer = false
    @State private var playerVideo: VodItem?
    @State private var selectedEpisode: FuliEpisode?

    // 线路 / 选集
    @State private var lines: [FuliLine] = []
    @State private var selectedLineIndex: Int = 0
    @State private var showLinePanel = false       // 线路选择面板
    @State private var showSelectPanel = false      // 选集面板

    // 播放地址解析相关
    @State private var isResolvingURL = false
    @State private var resolveError: String? = nil
    @State private var pendingEpisode: FuliEpisode? = nil

    // 下载相关
    @State private var showDownloadSheet = false
    @State private var showDownloadTip = false
    @State private var downloadTipText = ""
    @State private var isDownloading = false

    // MARK: - 当前线路/集数（计算属性）
    private var currentLine: FuliLine? {
        guard selectedLineIndex < lines.count else { return nil }
        return lines[selectedLineIndex]
    }

    private var currentEpisodes: [FuliEpisode] {
        currentLine?.episodes ?? []
    }

    // MARK: - Body
    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                FuliCoverImage(urlString: video.vodPic, referer: svc.imageReferer, sslBypass: svc.imageSSLBypass, contentMode: .fit)
                    .aspectRatio(16/9, contentMode: .fit)
                    .cornerRadius(12)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .center) {
                    if isLoading {
                        ProgressView().scaleEffect(2).tint(.white)
                    } else if errorMsg != nil {
                        EmptyView()
                    } else if detail?.episodes.isEmpty == false {
                        Button(action: { playFirst() }) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 64))
                                .foregroundColor(.white.opacity(0.95))
                                .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 2)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let err = errorMsg {
                    VStack(spacing: 12) {
                        Image(systemName: "play.slash")
                            .font(.system(size: 40)).foregroundColor(.secondary)
                        Text(err).font(.system(size: 14)).multilineTextAlignment(.center)
                        Button(action: { loadDetail() }) {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.system(size: 13)).foregroundColor(.white)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(Color.accentColor).cornerRadius(8)
                        }
                    }
                    .padding(.horizontal, 20)
                    Spacer()
                } else if let detail = detail {
                    Text(detail.vodName)
                        .font(.system(size: 18, weight: .bold)).padding(.horizontal, 16)

                    if !detail.episodes.isEmpty {
                        HStack(spacing: 12) {
                            // 左：选集按钮（当前线路有多集时才显示）
                            if currentEpisodes.count > 1 {
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showSelectPanel.toggle()
                                        showLinePanel = false
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "list.bullet")
                                        Text("选集(\(currentEpisodes.count))")
                                    }
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(showSelectPanel ? Color(hex: "2196F3") : .accentColor)
                                    .padding(.horizontal, 20).padding(.vertical, 10)
                                    .background(showSelectPanel ? Color(hex: "2196F3").opacity(0.15) : Color.accentColor.opacity(0.1))
                                    .cornerRadius(22)
                                }
                                .buttonStyle(.plain)
                            }

                            // 中：播放按钮
                            Button(action: { playFirst() }) {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text(currentEpisodes.count == 1 ? "立即播放" : "播放\(selectedEpisode?.name ?? currentEpisodes.first!.name)")
                                }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 28).padding(.vertical, 10)
                                .background(Color.accentColor).cornerRadius(22)
                            }
                            .buttonStyle(.plain)

                            // 右：线路按钮（多线路时才显示）
                            if lines.count > 1 {
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showLinePanel.toggle()
                                        showSelectPanel = false
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "line.3.horizontal.decrease")
                                        Text("线路(\(lines.count))")
                                    }
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(showLinePanel ? Color(hex: "2196F3") : .accentColor)
                                    .padding(.horizontal, 20).padding(.vertical, 10)
                                    .background(showLinePanel ? Color(hex: "2196F3").opacity(0.15) : Color.accentColor.opacity(0.1))
                                    .cornerRadius(22)
                                }
                                .buttonStyle(.plain)
                            }

                            // 下载按钮
                            Button(action: {
                                showDownloadSheet = true
                            }) {
                                HStack {
                                    Image(systemName: "arrow.down.circle")
                                    Text("下载")
                                }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 20).padding(.vertical, 10)
                                .background(Color.accentColor.opacity(0.1))
                                .cornerRadius(22)
                            }
                            .buttonStyle(.plain)
                            .disabled(isDownloading)
                        }

                        if let content = detail.vodContent, !content.isEmpty {
                            Text(content)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .lineLimit(4)
                                .padding(.horizontal, 16)
                        }
                    } else {
                        Text("未解析到播放地址")
                            .font(.system(size: 14)).foregroundColor(.secondary)
                        Spacer()
                    }
                    Spacer()
                }
            }
            .padding(.top, 20)
            .navigationTitle("播放")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { loadDetail() }
            .fullScreenCover(isPresented: $showPlayer) {
                if let playerVideo = playerVideo {
                    // 自动播放路链适配（v13.0 分流逻辑）：
                    // - 当前线路剧集 URL 本身是媒体直链（m3u8/mp4 等）且集数 >1 →
                    //   传 preParsedEpisodes，当前集用已解析直链，其他集保持原始直链，
                    //   播放器显示集数列表并支持内部切集/自动下一集。
                    // - 当前线路剧集 URL 是网页地址/需二次解析，或只有单集 → 传 nil，
                    //   播放器直接用 vodPlayUrl 播放当前集，避免把网页 URL 带入播放器
                    //   导致切集/自动下一集走解析器链路失败或播错资源。
                    let episodesToPass: [(name: String, url: String)]? = {
                        guard currentEpisodes.count > 1,
                              let firstUrl = currentEpisodes.first?.url,
                              MediaURLChecker.isLikelyDirectMediaUrl(firstUrl) else {
                            return nil
                        }
                        return currentEpisodes.map { ep in
                            if ep.id == selectedEpisode?.id,
                               let resolved = playerVideo.vodPlayUrl, !resolved.isEmpty {
                                return (ep.name, resolved)
                            }
                            return (ep.name, ep.url)
                        }
                    }()

                    VideoPlayerViewV2(
                        video: playerVideo,
                        preParsedEpisodes: episodesToPass
                    )
                }
            }

            // 线路选择悬浮面板
            if showLinePanel, lines.count > 1 {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showLinePanel = false
                        }
                    }

                FuliEpisodeFloatingPanel(
                    title: "选择线路",
                    episodes: lines.map { FuliEpisode(name: $0.name, url: $0.name) },
                    selectedEpisode: FuliEpisode(name: currentLine?.name ?? "", url: currentLine?.name ?? ""),
                    onSelect: { ep in
                        if let idx = lines.firstIndex(where: { $0.name == ep.name }) {
                            selectedLineIndex = idx
                            selectedEpisode = lines[idx].episodes.first
                        }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showLinePanel = false
                        }
                    }
                )
                .frame(maxWidth: 220)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.85)),
                    removal: .opacity.combined(with: .scale(scale: 0.9))
                ))
                .zIndex(50)
            }

            // 选集悬浮面板
            if showSelectPanel, currentEpisodes.count > 1 {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSelectPanel = false
                        }
                    }

                FuliEpisodeFloatingPanel(
                    title: "选集",
                    episodes: currentEpisodes,
                    selectedEpisode: selectedEpisode ?? currentEpisodes.first,
                    onSelect: { ep in
                        selectedEpisode = ep
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showSelectPanel = false
                        }
                        playEpisode(ep)
                    }
                )
                .frame(maxWidth: 220)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.85)),
                    removal: .opacity.combined(with: .scale(scale: 0.9))
                ))
                .zIndex(50)
            }

            // 播放地址解析加载浮层
            if isResolvingURL || resolveError != nil {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    if isResolvingURL {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("正在解析播放地址...")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                    } else if let err = resolveError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36))
                            .foregroundColor(.orange)
                        Text("播放地址解析失败")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                        HStack(spacing: 12) {
                            Button(action: { cancelResolve() }) {
                                Text("取消")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.2))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)

                            Button(action: { retryResolve() }) {
                                Text("重试")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color.accentColor)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(24)
                .background(Color(UIColor.systemBackground).opacity(0.95))
                .cornerRadius(16)
                .shadow(radius: 20)
                .padding(.horizontal, 40)
                .zIndex(100)
            }

            // 下载提示
            if showDownloadTip {
                VStack {
                    Spacer()
                    Text(downloadTipText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .sheet(isPresented: $showDownloadSheet) {
            FuliDownloadSheet(
                episodes: currentEpisodes,
                lineName: currentLine?.name ?? "",
                onSelect: { indices in
                    handleBatchDownload(indices: indices)
                    showDownloadSheet = false
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - 数据加载
    private func loadDetail() {
        isLoading = true; errorMsg = nil; detail = nil
        Task {
            await svc.ensureHostReady()
            let result = await svc.fetchDetail(vodId: video.vodId)
            await MainActor.run {
                detail = result; isLoading = false
                if result.episodes.isEmpty {
                    errorMsg = "未解析到播放地址"
                } else {
                    // 检测线路分组
                    lines = detectLines(from: result.episodes)
                    selectedLineIndex = 0
                    selectedEpisode = lines.first?.episodes.first
                }
            }
        }
    }

    // MARK: - 播放控制
    private func playFirst() {
        guard let first = currentEpisodes.first else { return }
        selectedEpisode = first
        playEpisode(first)
    }

    private func playEpisode(_ episode: FuliEpisode) {
        pendingEpisode = episode
        resolveEpisode()
    }

    private func resolveEpisode() {
        guard let episode = pendingEpisode else { return }
        isResolvingURL = true
        resolveError = nil

        Task {
            await svc.ensureHostReady()
            let result = await svc.fetchPlayerURL(episode: episode)

            // 当 parse=1 时，URL 是网页地址而非直链，需要走解析器链路提取直链。
            // 先在 Bridge 层尝试 SpiderManager.parsePlayUrl（含 extractDirectPlayURL + WKWebView 回退），
            // 成功则用解析后的直链播放；失败则仍把原始 URL 传给播放器，播放器内部会再走一遍解析器。
            var finalUrl = result.url
            var finalHeaders = result.headers
            if result.parse == 1 && !result.url.isEmpty {
                if let parsedUrl = await SpiderManager.shared.parsePlayUrl(from: result.url) {
                    print("[FuliBridge] ✅ parse=1 解析成功: \(parsedUrl.prefix(80))")
                    finalUrl = parsedUrl
                    finalHeaders = result.headers  // 保留原始 headers（Referer 等）
                } else {
                    print("[FuliBridge] ⚠️ parse=1 解析失败，传原始 URL 给播放器重试: \(result.url.prefix(60))")
                }
            }

            await MainActor.run {
                isResolvingURL = false
                if finalUrl.isEmpty {
                    resolveError = "无法获取有效的播放地址"
                } else {
                    playerVideo = VodItem(
                        vodId: video.vodId,
                        vodName: "\(video.vodName) \(episode.name)",
                        vodPic: video.vodPic,
                        vodRemarks: "[福利]\(svc.platformName)",
                        vodPlayUrl: finalUrl,
                        customHeaders: finalHeaders,
                        engineKey: "__fuli_welfare__:\(svc.platformKey)"
                    )
                    showPlayer = true
                    pendingEpisode = nil
                }
            }
        }
    }

    private func retryResolve() {
        resolveError = nil
        resolveEpisode()
    }

    private func cancelResolve() {
        resolveError = nil
        pendingEpisode = nil
        isResolvingURL = false
    }

    // MARK: - 批量下载
    private func handleBatchDownload(indices: [Int]) {
        guard !currentEpisodes.isEmpty, !indices.isEmpty else { return }

        isDownloading = true
        let episodesToDownload = indices.compactMap { currentEpisodes.indices.contains($0) ? currentEpisodes[$0] : nil }
        let platformName = svc.platformName
        let platformKey = svc.platformKey
        let videoName = video.vodName
        let videoPic = video.vodPic
        let videoId = video.vodId

        Task {
            var successCount = 0
            for episode in episodesToDownload {
                // 解析播放地址
                await svc.ensureHostReady()
                let result = await svc.fetchPlayerURL(episode: episode)

                var finalUrl = result.url
                var finalHeaders = result.headers

                // parse=1 时需要二次解析
                if result.parse == 1 && !result.url.isEmpty {
                    if let parsedUrl = await SpiderManager.shared.parsePlayUrl(from: result.url) {
                        finalUrl = parsedUrl
                    }
                }

                guard !finalUrl.isEmpty else { continue }

                let record = DownloadRecord(
                    name: "\(videoName) \(episode.name)",
                    laiyuan: "[福利]\(platformName)",
                    imgurl: videoPic,
                    detailurl: videoId,
                    playurl: finalUrl,
                    jishu: successCount + 1,
                    progress: 0,
                    status: "pending",
                    addedAt: Int64(Date().timeIntervalSince1970),
                    sourceType: "normal",
                    engineKey: "__fuli_welfare__:\(platformKey)",
                    vodId: videoId,
                    headers: {
                        guard !finalHeaders.isEmpty,
                              let data = try? JSONEncoder().encode(finalHeaders),
                              let json = String(data: data, encoding: .utf8) else { return nil }
                        return json
                    }()
                )
                await MainActor.run {
                    DownloadManager.shared.enqueueDownload(record: record)
                }
                successCount += 1
            }

            await MainActor.run {
                isDownloading = false
                if successCount > 0 {
                    downloadTipText = "已添加 \(successCount) 集到下载"
                    showDownloadTip = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showDownloadTip = false }
                } else {
                    downloadTipText = "下载失败，未能解析到播放地址"
                    showDownloadTip = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showDownloadTip = false }
                }
            }
        }
    }

    // MARK: - 线路分组检测
    /// 从扁平 episodes 数组中检测并分组线路。
    /// WelfareResultMapper 在多线路时会给集名加 [线路名] 前缀，如 "[线路1] 第1集"。
    /// 无前缀的视为单线路（"在线播放"）。
    private func detectLines(from episodes: [FuliEpisode]) -> [FuliLine] {
        var lineOrder: [String] = []
        var lineMap: [String: [FuliEpisode]] = [:]

        for ep in episodes {
            if ep.name.hasPrefix("["),
               let closeIdx = ep.name.firstIndex(of: "]") {
                // 有 [线路名] 前缀 → 提取线路名和纯集名
                let afterBracket = ep.name.index(after: ep.name.startIndex)
                let lineName = String(ep.name[afterBracket..<closeIdx])
                let epName = String(ep.name[ep.name.index(after: closeIdx)...])
                    .trimmingCharacters(in: .whitespaces)

                if !lineOrder.contains(lineName) {
                    lineOrder.append(lineName)
                    lineMap[lineName] = []
                }
                lineMap[lineName]?.append(FuliEpisode(name: epName, url: ep.url))
            } else {
                // 无前缀 → 单线路
                let defaultLine = "在线播放"
                if !lineOrder.contains(defaultLine) {
                    lineOrder.append(defaultLine)
                    lineMap[defaultLine] = []
                }
                lineMap[defaultLine]?.append(ep)
            }
        }

        return lineOrder.map { name in
            FuliLine(name: name, episodes: lineMap[name] ?? [])
        }
    }
}

// MARK: - 线路/选集悬浮面板
//
// 仿照播放器倍速面板（PlayerSettingsPanelV2）设计的悬浮选择器。
// 显示为半透明背景上的垂直列表面板，点击外部区域自动关闭。
// 通用于"线路选择"和"选集"两种场景，通过 title 参数区分标题。
struct FuliEpisodeFloatingPanel: View {
    let title: String
    let episodes: [FuliEpisode]
    let selectedEpisode: FuliEpisode?
    let onSelect: (FuliEpisode) -> Void

    init(title: String = "选择线路",
         episodes: [FuliEpisode],
         selectedEpisode: FuliEpisode?,
         onSelect: @escaping (FuliEpisode) -> Void) {
        self.title = title
        self.episodes = episodes
        self.selectedEpisode = selectedEpisode
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // 列表
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(episodes) { ep in
                        let isSelected = ep.id == selectedEpisode?.id
                        Button(action: { onSelect(ep) }) {
                            HStack {
                                Text(ep.name)
                                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                                    .foregroundColor(isSelected ? Color(hex: "2196F3") : .white.opacity(0.85))
                                    .lineLimit(1)
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(Color(hex: "2196F3"))
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(
                                isSelected ? Color(hex: "2196F3").opacity(0.15) : Color.clear
                            )
                        }
                        .buttonStyle(PlainButtonStyle())

                        if ep.id != episodes.last?.id {
                            Divider()
                                .background(Color.white.opacity(0.08))
                                .padding(.leading, 14)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .background(Color.black.opacity(0.85))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 4)
    }
}

// MARK: - 福利下载选集弹窗
private struct FuliDownloadSheet: View {
    let episodes: [FuliEpisode]
    let lineName: String
    let onSelect: ([Int]) -> Void

    @State private var selectedIndices: Set<Int> = []
    @Environment(\.dismiss) private var dismiss

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选择下载集数")
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(lineName) - 共 \(episodes.count) 集，已选 \(selectedIndices.count) 集")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()

                Button("全选") {
                    if selectedIndices.count == episodes.count {
                        selectedIndices.removeAll()
                    } else {
                        selectedIndices = Set(0..<episodes.count)
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(episodes.enumerated()), id: \.offset) { index, ep in
                        Button(action: {
                            if selectedIndices.contains(index) {
                                selectedIndices.remove(index)
                            } else {
                                selectedIndices.insert(index)
                            }
                        }) {
                            Text(ep.name)
                                .font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .lineLimit(1)
                                .background(selectedIndices.contains(index) ? Color.accentColor : Color.gray.opacity(0.12))
                                .foregroundColor(selectedIndices.contains(index) ? .white : .primary)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 80)
            }

            VStack {
                Button(action: {
                    let sorted = selectedIndices.sorted()
                    onSelect(sorted)
                    dismiss()
                }) {
                    Text("下载选中(\(selectedIndices.count))")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(selectedIndices.isEmpty ? Color.gray : Color.accentColor)
                        .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .disabled(selectedIndices.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}
