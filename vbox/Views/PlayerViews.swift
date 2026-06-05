import SwiftUI
import AVKit
import AVFoundation

// MARK: - 视频详情视图
struct VideoDetailView: View {
    let video: VodItem
    @State private var showPlayer = false
    @State private var isFavorite = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                // 封面和播放按钮
                ZStack(alignment: .bottomLeading) {
                    AsyncImage(url: URL(string: video.vodPic)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure(_):
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                        case .empty:
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                        @unknown default:
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                        }
                    }
                    .frame(height: 220)
                    .clipped()

                    // 渐变遮罩
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.0),
                            Color.black.opacity(0.6),
                            Color.black.opacity(0.95)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // 播放按钮
                    Button(action: {
                        print("[DetailDebug] ▶️ 封面播放按钮 tapped, video: \(video.vodName)")
                        showPlayer = true
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color(hex: "E11D48"))
                                .frame(width: 70, height: 70)

                            // 液态光晕效果
                            LiquidGlow()
                                .frame(width: 90, height: 90)
                                .blur(radius: 15)
                                .opacity(0.6)

                            Image(systemName: "play.fill")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.white)
                                .offset(x: 3)
                        }
                    }
                    .padding(16)

                    // 收藏按钮
                    VStack {
                        Spacer()

                        HStack {
                            Spacer()

                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    isFavorite.toggle()
                                }
                            }) {
                                Image(systemName: isFavorite ? "heart.fill" : "heart")
                                    .font(.system(size: 24))
                                    .foregroundColor(isFavorite ? Color(hex: "E11D48") : .white)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        Circle()
                                            .fill(.ultraThinMaterial)
                                    )
                            }
                            .padding(16)
                        }
                    }
                }

                // 信息区域
                VStack(alignment: .leading, spacing: 16) {
                    // 标题和标签
                    VStack(alignment: .leading, spacing: 10) {
                        Text(video.vodName)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.primary)

                        HStack(spacing: 12) {
                            TagLabel(text: video.vodRemarks ?? "")
                            TagLabel(text: video.vodYear ?? "")
                            TagLabel(text: "高清")
                        }
                    }

                    // 操作按钮
                    HStack(spacing: 16) {
                        ActionButton(icon: "play.fill", title: "播放") {
                            print("[DetailDebug] ▶️ 操作栏播放按钮 tapped, video: \(video.vodName)")
                            showPlayer = true
                        }

                        ActionButton(icon: "list.bullet", title: "选集") {
                            // 显示选集列表
                        }

                        ActionButton(icon: "square.and.arrow.down", title: "下载") {
                            // 下载视频
                        }

                        ActionButton(icon: "square.and.arrow.up", title: "分享") {
                            // 分享视频
                        }
                    }

                    // 简介
                    VStack(alignment: .leading, spacing: 8) {
                        Text("剧情简介")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)

                        Text("这是一部精彩的影视作品，讲述了扣人心弦的故事情节，展现了丰富的人物形象和深刻的主题内涵。")
                            .font(.system(size: 14))
                            .foregroundColor(Color.secondary)
                            .lineSpacing(4)
                    }

                    // 剧集列表
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("剧集列表")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)

                            Spacer()

                            Text("共24集")
                                .font(.system(size: 13))
                                .foregroundColor(Color.secondary)
                        }

                        EpisodeGridView()
                    }

                    // 相关推荐
                    RelatedVideosView()
                }
                .padding(20)
                .padding(.bottom, 100)
            }
        .background(Color(hex: "000000"))
        .ignoresSafeArea()
        .fullScreenCover(isPresented: $showPlayer) {
            VideoPlayerView(video: video)
        }
        
        // 返回按钮（悬浮在左上角）
        VStack {
            HStack {
                Button(action: { dismiss() }) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 40, height: 40)
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                }
                .padding(.leading, 16)
                .padding(.top, 50)
                Spacer()
            }
            Spacer()
        }
        .zIndex(1000)
    }  // ZStack
}  // body
}  // VideoDetailView
}

// 液态光晕效果
struct LiquidGlow: View {
    @State private var phase: Double = 0

    var body: some View {
        ZStack {
            ForEach(0..<3) { index in
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: "E11D48").opacity(0.5),
                                Color(hex: "F43F5E").opacity(0.3),
                                Color(hex: "7C3AED").opacity(0.2)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)
                    .offset(
                        x: CGFloat(sin(phase + Double(index)) * 5),
                        y: CGFloat(cos(phase + Double(index)) * 5)
                    )
                    .blur(radius: 20)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: true)) {
                phase = .pi * 2
            }
        }
    }
}

// 标签标签
struct TagLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.1),
                                Color.white.opacity(0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
    }
}

// 操作按钮
struct ActionButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    // 液态背景
                    LiquidBackground()
                        .frame(width: 50, height: 50)
                        .blur(radius: 8)
                        .opacity(0.5)

                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                .frame(width: 50, height: 50)

                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// 剧集网格视图
struct EpisodeGridView: View {
    @State private var selectedEpisode = 1

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            ForEach(1..<25) { episode in
                EpisodeButton(
                    episode: episode,
                    isSelected: selectedEpisode == episode
                ) {
                    selectedEpisode = episode
                }
            }
        }
    }
}

// 剧集按钮
struct EpisodeButton: View {
    let episode: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(episode)")
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : .primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        if isSelected {
                            // 液态背景
                            LiquidBackground()
                                .blur(radius: 8)
                                .opacity(0.6)
                        }

                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.ultraThinMaterial).foregroundColor(isSelected ? Color(hex: "E11D48") : .primary)
                    }
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// 相关推荐视图
struct RelatedVideosView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("相关推荐")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)

            LazyVStack(spacing: 12) {
                ForEach(mockVideos.prefix(5)) { video in
                    RelatedVideoRow(video: video)
                }
            }
        }
    }
}

// 相关视频行
struct RelatedVideoRow: View {
    let video: VodItem

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: video.vodPic)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure(_):
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                case .empty:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                @unknown default:
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                }
            }
            .frame(width: 110, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(video.vodName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(video.vodRemarks ?? "")
                        .font(.system(size: 12))
                        .foregroundColor(Color.secondary)

                    Text("•")
                        .font(.system(size: 12))
                        .foregroundColor(Color.secondary)

                    Text(video.vodYear ?? "")
                        .font(.system(size: 12))
                        .foregroundColor(Color.secondary)
                }

                Text("2024-01-15 更新")
                    .font(.system(size: 11))
                    .foregroundColor(Color.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thinMaterial)
        )
    }
}

// MARK: - 视频播放器视图
struct VideoPlayerView: View {
    let video: VodItem
    @State private var player: AVPlayer?
    @State private var isPlaying = true
    @State private var showControls = true
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var playbackSpeed: Double = 1.0
    @State private var volume: Double = 1.0
    @State private var isMuted = false
    @State private var isFullscreen = true
    @State private var isPictureInPicture = false
    @State private var controlsOpacity: Double = 1.0
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var debugLog: String = ""

    @Environment(\.dismiss) private var dismiss
    @StateObject private var playerTimeObserver = PlayerTimeObserver()

    private func log(_ msg: String) {
        print("[PlayerDebug] \(msg)")
        debugLog = msg
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            if isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("加载中...")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    if !debugLog.isEmpty {
                        Text(debugLog)
                            .font(.system(size: 11))
                            .foregroundColor(.yellow.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                }
            } else if let error = loadError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Button("返回") { dismiss() }
                        .foregroundColor(Color(hex: "E11D48"))
                }
            } else if let player = player {
                VideoPlayer(player: player)
                    .overlay(
                        Color.black.opacity(0.01)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    showControls.toggle()
                                    controlsOpacity = showControls ? 1.0 : 0.0
                                }
                            }
                    )
            }

            // 控制层
            if showControls && !isLoading && loadError == nil {
                VStack(spacing: 0) {
                    TopControlBar(
                        title: video.vodName,
                        isPlaying: $isPlaying,
                        isMuted: $isMuted,
                        volume: $volume,
                        onBack: { dismiss() },
                        onPlayPause: togglePlayPause
                    )
                    .opacity(controlsOpacity)

                    Spacer()

                    BottomControlBar(
                        currentTime: currentTime,
                        duration: duration,
                        playbackSpeed: $playbackSpeed,
                        isPlaying: $isPlaying,
                        onSeek: seekTo,
                        onPlayPause: togglePlayPause,
                        onSpeedChange: changePlaybackSpeed,
                        onPictureInPicture: togglePictureInPicture
                    )
                    .opacity(controlsOpacity)
                }
                .background(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.7),
                            Color.clear,
                            Color.black.opacity(0.7)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .statusBar(hidden: isFullscreen)
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            player?.pause()
        }
    }

    private func setupPlayer() {
        // 优先使用已有的播放地址
        let urlString = video.vodPlayUrl ?? ""
        if !urlString.isEmpty {
            log("已有播放地址: \(urlString.prefix(60))...")
            if let url = URL(string: urlString) {
                initPlayer(url: url)
                return
            } else {
                log("⚠️ vodPlayUrl 无效URL")
            }
        }

        log("无内置播放地址，vodId=\(video.vodId)")
        // 没有播放地址，通过蜘蛛获取
        isLoading = true
        Task {
            await resolvePlayUrl()
        }
    }

    private func resolvePlayUrl() async {
        let spider = SpiderManager.shared
        
        // Step 1: detailContent
        log("1/4 调用 detailContent(\(video.vodId))...")
        if let detail = await spider.getDetail(ids: video.vodId) {
            log("2/4 detailContent: vodName=\(detail.vodName), vodPlayFrom=\(detail.vodPlayFrom?.prefix(30) ?? "nil"), vodPlayUrl=\(detail.vodPlayUrl?.prefix(50) ?? "nil")")
            
            if let playUrl = detail.vodPlayUrl, !playUrl.isEmpty,
               let url = URL(string: playUrl) {
                log("✅ 直链播放地址就绪")
                await MainActor.run { initPlayer(url: url) }
                return
            }
            
            if let playFrom = detail.vodPlayFrom, let playUrlRaw = detail.vodPlayUrl {
                let urls = parsePlayUrls(playFrom: playFrom, playUrl: playUrlRaw)
                if let firstUrl = urls.first, let url = URL(string: firstUrl) {
                    log("✅ 从 vodPlayFrom 提取直链")
                    await MainActor.run { initPlayer(url: url) }
                    return
                }
            }
        } else {
            log("⚠️ detailContent 返回 nil")
        }
        
        // Step 2: playerContent — TVBox 蜘蛛播放解析
        log("3/4 调用 playerContent...")
        if let playResult = await spider.getPlayerContent(
            vodId: video.vodId,
            flag: "play",
            url: video.vodPlayUrl ?? ""
        ) {
            let playUrl = playResult.playUrl ?? playResult.url ?? ""
            log("playerContent: playUrl=\(playUrl.prefix(60)), headers=\(playResult.header?.count ?? 0)个")
            
            if !playUrl.isEmpty, let url = URL(string: playUrl) {
                log("✅ playerContent 播放地址就绪")
                await MainActor.run { initPlayer(url: url) }
                return
            }
            log("⚠️ playerContent 返回 playUrl/url 为空")
        } else {
            log("⚠️ playerContent 返回 nil")
        }
        
        // Step 3: nativeDetail
        log("4/4 nativeDetail(订阅源)...")
        let nativeDetail = await spider.nativeDetail(ids: video.vodId, name: video.vodName)
        if let nd = nativeDetail {
            log("nativeDetail: vodName=\(nd.vodName)")
            
            // 显示所有播放相关字段的详细信息
            log("  vodPlayFrom字段内容: '\(nd.vodPlayFrom ?? "nil")'")
            log("  vodPlayUrl字段内容: '\(nd.vodPlayUrl?.prefix(100) ?? "nil")'")
            
            // 检查vodPlayUrl的长度和内容
            if let playUrl = nd.vodPlayUrl, !playUrl.isEmpty {
                log("  vodPlayUrl长度: \(playUrl.count)字符")
                log("  vodPlayUrl前50字符: \(String(playUrl.prefix(50)))")
                log("  vodPlayUrl后50字符: \(String(playUrl.suffix(50)))")
                
                // 检查是否为 HTTP/HTTPS 直链
                if playUrl.hasPrefix("http://") || playUrl.hasPrefix("https://") {
                    // 检查是否为视频直链格式
                    if playUrl.hasSuffix(".m3u8") || playUrl.hasSuffix(".mp4") || playUrl.contains(".m3u8?") {
                        log("✅ nativeDetail 检测到视频直链")
                        if let url = URL(string: playUrl) {
                            await MainActor.run { initPlayer(url: url) }
                            return
                        }
                    } else {
                        // 可能是HTML播放页，尝试解析
                        log("⚠️ nativeDetail 检测到HTML播放页，尝试解析器...")
                        if let parsedUrl = await spider.parsePlayUrl(from: playUrl) {
                            log("✅ 解析器成功解析出视频直链: \(parsedUrl.prefix(60))...")
                            if let url = URL(string: parsedUrl) {
                                await MainActor.run { initPlayer(url: url) }
                                return
                            }
                        } else {
                            log("❌ 解析器失败，无法解析HTML播放页")
                        }
                    }
                } else {
                    log("⚠️ vodPlayUrl不是HTTP/HTTPS开头，可能是特殊格式")
                }

                // 尝试解析 TVBox 格式的播放地址
                let urls = parsePlayUrls(playFrom: nd.vodPlayFrom ?? "", playUrl: playUrl)
                log("  从vodPlayUrl解析出\(urls.count)个地址")
                if let firstUrl = urls.first {
                    log("  第一集地址: \(firstUrl.prefix(60))...")
                    // 检查第一集URL是否为HTML播放页
                    if firstUrl.hasSuffix(".m3u8") || firstUrl.hasSuffix(".mp4") {
                        if let url = URL(string: firstUrl) {
                            log("✅ nativeDetail 解析出视频直链")
                            await MainActor.run { initPlayer(url: url) }
                            return
                        }
                    } else {
                        // 尝试解析HTML播放页
                        log("⚠️ nativeDetail 第一集为HTML播放页，尝试解析器...")
                        if let parsedUrl = await spider.parsePlayUrl(from: firstUrl) {
                            log("✅ 解析器成功解析出第一集视频直链: \(parsedUrl.prefix(60))...")
                            if let url = URL(string: parsedUrl) {
                                await MainActor.run { initPlayer(url: url) }
                                return
                            }
                        } else {
                            log("❌ 解析器失败，无法解析第一集HTML播放页")
                        }
                    }
                } else {
                    log("⚠️ parsePlayUrls未能解析出任何地址")
                }
            } else {
                log("⚠️ vodPlayUrl为空或nil")
            }

            // 检查 vodPlayFrom 和 vodPlayUrl 组合
            if let playFrom = nd.vodPlayFrom, !playFrom.isEmpty,
               let playUrlRaw = nd.vodPlayUrl, !playUrlRaw.isEmpty {
                log("尝试从vodPlayFrom+vodPlayUrl组合解析...")
                let urls = parsePlayUrls(playFrom: playFrom, playUrl: playUrlRaw)
                log("  从组合解析出\(urls.count)个地址")
                if let firstUrl = urls.first {
                    log("  组合第一集地址: \(firstUrl.prefix(60))...")
                    // 检查是否为HTML播放页
                    if firstUrl.hasSuffix(".m3u8") || firstUrl.hasSuffix(".mp4") {
                        if let url = URL(string: firstUrl) {
                            log("✅ nativeDetail 从 vodPlayFrom 提取视频直链")
                            await MainActor.run { initPlayer(url: url) }
                            return
                        }
                    } else {
                        // 尝试解析HTML播放页
                        log("⚠️ nativeDetail vodPlayFrom第一集为HTML播放页，尝试解析器...")
                        if let parsedUrl = await spider.parsePlayUrl(from: firstUrl) {
                            log("✅ 解析器成功解析出vodPlayFrom视频直链: \(parsedUrl.prefix(60))...")
                            if let url = URL(string: parsedUrl) {
                                await MainActor.run { initPlayer(url: url) }
                                return
                            }
                        } else {
                            log("❌ 解析器失败，无法解析vodPlayFrom HTML播放页")
                        }
                    }
                }
            }

            log("⚠️ nativeDetail 有记录但无有效播放地址")
            log("  vodPlayFrom: \(nd.vodPlayFrom ?? "nil")")
            log("  vodPlayUrl: \(nd.vodPlayUrl ?? "nil")")
        } else {
            log("⚠️ nativeDetail 返回 nil")
        }

        await MainActor.run {
            isLoading = false
            loadError = "无法获取播放地址\n最后状态: \(debugLog)"
        }
    }

    private func parsePlayUrls(playFrom: String, playUrl: String) -> [String] {
        // TVBox 格式: playFrom = "线路1$$$线路2"  playUrl = "第1集$url1#第2集$url2$$$第1集$url3"
        // 简化：提取所有 http 开头的 URL
        var results: [String] = []
        let pattern = #"https?://[^\s#]+"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(playUrl.startIndex..., in: playUrl)
            let matches = regex.matches(in: playUrl, range: range)
            for m in matches {
                if let r = Range(m.range, in: playUrl) {
                    results.append(String(playUrl[r]))
                }
            }
        }
        return results
    }

    private func initPlayer(url: URL) {
        let p = AVPlayer(url: url)
        p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak p] time in
            currentTime = time.seconds
        }
        p.currentItem?.asset.loadValuesAsynchronously(forKeys: ["duration"]) {
            DispatchQueue.main.async {
                if let d = p.currentItem?.asset.duration {
                    duration = CMTimeGetSeconds(d)
                }
            }
        }
        p.play()
        player = p
        isPlaying = true
        isLoading = false
    }

    private func togglePlayPause() {
        guard let player = player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    private func seekTo(_ time: Double) {
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
    }

    private func changePlaybackSpeed(_ speed: Double) {
        player?.rate = Float(speed)
    }

    private func togglePictureInPicture() { isPictureInPicture.toggle() }
}

// 顶部控制栏
struct TopControlBar: View {
    let title: String
    @Binding var isPlaying: Bool
    @Binding var isMuted: Bool
    @Binding var volume: Double
    let onBack: () -> Void
    let onPlayPause: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // 返回按钮
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                    )
            }

            // 标题
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text("正在播放")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 音量控制
            Button(action: {
                isMuted.toggle()
            }) {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                    )
            }

            // 更多按钮
            Button(action: {}) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(.ultraThinMaterial)
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            // 底部毛玻璃效果
            LinearGradient(
                colors: [
                    Color.black.opacity(0.8),
                    Color.black.opacity(0.4),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// 底部控制栏
struct BottomControlBar: View {
    let currentTime: Double
    let duration: Double
    @Binding var playbackSpeed: Double
    @Binding var isPlaying: Bool
    let onSeek: (Double) -> Void
    let onPlayPause: () -> Void
    let onSpeedChange: (Double) -> Void
    let onPictureInPicture: () -> Void

    @State private var isDragging = false
    @State private var sliderValue: Double = 0

    var body: some View {
        VStack(spacing: 16) {
            // 进度条
            VStack(spacing: 8) {
                ProgressSlider(
                    value: $sliderValue,
                    range: 0...duration,
                    isDragging: $isDragging
                ) { newValue in
                    onSeek(newValue)
                }

                // 时间显示
                HStack {
                    Text(formatTime(currentTime))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))

                    Spacer()

                    Text(formatTime(duration))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            // 控制按钮
            HStack(spacing: 24) {
                // 倍速按钮
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                        Button(action: { onSpeedChange(speed) }) {
                            HStack {
                                Text("\(speed)x")
                                if playbackSpeed == speed {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text("\(playbackSpeed)x")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .frame(width: 44)
                }

                Spacer()

                // 快退
                Button(action: { onSeek(max(0, currentTime - 10)) }) {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                }

                // 播放/暂停按钮
                Button(action: onPlayPause) {
                    ZStack {
                        // 液态光晕
                        if isPlaying {
                            LiquidGlow()
                                .frame(width: 80, height: 80)
                                .blur(radius: 12)
                                .opacity(0.5)
                        }

                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)
                            .offset(isPlaying ? .zero : CGSize(width: 3, height: 0))
                    }
                    .frame(width: 70, height: 70)
                }

                // 快进
                Button(action: { onSeek(min(duration, currentTime + 10)) }) {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                }

                Spacer()

                // 画中画按钮
                Button(action: onPictureInPicture) {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .frame(width: 44)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            // 底部毛玻璃效果
            LinearGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(0.4),
                    Color.black.opacity(0.8)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .onChange(of: currentTime) { newValue in
            if !isDragging {
                sliderValue = newValue
            }
        }
    }

    private func formatTime(_ time: Double) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// 自定义进度条
struct ProgressSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    @Binding var isDragging: Bool
    let onValueChanged: (Double) -> Void

    @GestureState private var isHighlighting = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 背景轨道
                Capsule()
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 6)

                // 已播放进度
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * progressRatio, height: 6)

                // 拖动手柄
                Circle()
                    .fill(Color.white)
                    .frame(width: isDragging || isHighlighting ? 18 : 14, height: isDragging || isHighlighting ? 18 : 14)
                    .offset(x: geometry.size.width * progressRatio - (isDragging || isHighlighting ? 9 : 7))
                    .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        updateValue(at: value.location.x, in: geometry.size.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 20)
    }

    private var progressRatio: Double {
        guard range.upperBound > 0 else { return 0 }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func updateValue(at location: Double, in width: Double) {
        let ratio = max(0, min(1, location / width))
        let newValue = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
        value = newValue
        onValueChanged(newValue)
    }
}

// 播放器时间观察者
class PlayerTimeObserver: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
}

// 画中画控制器包装
@available(iOS 16.0, *)
struct PictureInPictureControllerRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController()
        c.player = context.coordinator.player
        return c
    }
    func updateUIViewController(_: AVPlayerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator { var player: AVPlayer? }
}