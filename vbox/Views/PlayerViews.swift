import SwiftUI
import AVKit
import AVFoundation

// MARK: - 视频详情视图 (新版：底栏 + 演职人员 + 修复闪跳)
struct VideoDetailView: View {
    let video: VodItem
    let searchKeyword: String?

    init(video: VodItem, searchKeyword: String? = nil) {
        self.video = video
        self.searchKeyword = searchKeyword
    }

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    // 播放器
    @State private var showPlayer = false
    @State private var selectedPanVideo: VodItem?
    @State private var selectedEpisodeVideo: VodItem?

    // 网盘
    @State private var panLinks: [(url: String, name: String)] = []
    @State private var isLoadingPan = false

    // 详情数据（加载完成后不再变化，避免闪跳）
    @State private var detailVideo: VodItem?
    @State private var isLoadingDetail = false
    @State private var hasLoadedDetail = false

    // 播放源（使用 @State 缓存，避免计算属性频繁变化）
    @State private var allSources: [(name: String, episodes: [(name: String, url: String)])] = []
    @State private var selectedSourceIndex = 0

    // 演职人员
    @State private var actors: [DoubanCelebrity] = []
    @State private var directors: [DoubanCelebrity] = []
    @State private var writers: [DoubanCelebrity] = []
    @State private var isLoadingCredits = false

    // TMDB 大封面图 / logo
    @State private var tmdbBackdropURL: String? = nil
    @State private var tmdbPosterURL: String? = nil
    @State private var tmdbLogoURL: String? = nil
    @State private var tmdbMediaType: String = "movie"
    @State private var isLoadingTMDB = false

    // 演职人员分类
    @State private var selectedCastTab = "演员"

    // 底栏选集弹窗
    @State private var showEpisodeSheet = false

    // 收藏
    @State private var isFavorite = false
    @State private var favoriteId: Int? = nil
    @State private var showDownloadTip = false

    private var isCloudVideo: Bool { video.vodRemarks?.hasPrefix("☁️") == true }
    private var displayVideo: VodItem { detailVideo ?? video }
    private var searchName: String { searchKeyword ?? video.vodName }

    private var fallbackBackground: some View {
        LinearGradient(
            colors: [
                Color(hex: "3D4A5C"),
                Color(hex: "2A323E"),
                Color(hex: "121418")
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var episodes: [(name: String, url: String)] {
        guard !allSources.isEmpty else { return [] }
        let idx = min(selectedSourceIndex, allSources.count - 1)
        return allSources[idx].episodes
    }

    // MARK: - 初始化播放源（只执行一次，避免闪跳）
    private func initializeSources() {
        let sources = parseAllSources(from: displayVideo.vodPlayUrl, playFrom: displayVideo.vodPlayFrom)
        allSources = sources
        selectedSourceIndex = 0
    }

    // MARK: - 加载真实详情（不触发UI闪跳）
    private func loadRealDetailIfNeeded() {
        guard !hasLoadedDetail, !isLoadingDetail else { return }
        isLoadingDetail = true
        Task {
            let detail = await SpiderManager.shared.getDetail(ids: video.vodId, name: video.vodName)
            await MainActor.run {
                hasLoadedDetail = true
                // 只在初始video没有playUrl时才用detail补充，避免覆盖已有数据
                if video.vodPlayUrl?.isEmpty != false,
                   let detail, detail.vodPlayUrl?.isEmpty == false {
                    let sources = parseAllSources(from: detail.vodPlayUrl, playFrom: detail.vodPlayFrom)
                    if !sources.isEmpty {
                        allSources = sources
                        selectedSourceIndex = 0
                    }
                }
                isLoadingDetail = false
            }
        }
    }

    // MARK: - 加载演职人员
    private func loadCredits() {
        guard !isLoadingCredits else { return }
        isLoadingCredits = true
        Task {
            let result = await DoubanService.shared.fetchCredits(for: searchName)
            await MainActor.run {
                actors = result.actors
                directors = result.directors
                writers = result.writers
                isLoadingCredits = false
            }
        }
    }

    // MARK: - 加载 TMDB 数据（logo、海报、演员）
    private func loadTMDBData() {
        guard !isLoadingTMDB else { return }
        isLoadingTMDB = true
        Task {
            guard let searchResult = await TMDBService.shared.searchMovie(name: searchName, year: video.vodYear) else {
                await MainActor.run { isLoadingTMDB = false }
                return
            }

            let id = searchResult.id
            let mediaType = searchResult.mediaType
            await MainActor.run { tmdbMediaType = mediaType }

            async let imagesTask = TMDBService.shared.fetchImages(id: id, mediaType: mediaType)
            async let creditsTask = TMDBService.shared.fetchCredits(id: id, mediaType: mediaType)

            let images = await imagesTask
            let credits = await creditsTask

            await MainActor.run {
                // logo 优先 w500 走代理
                if let logoPath = images?.bestLogo?.w500URL {
                    tmdbLogoURL = TMDBService.shared.proxiedImageURL(logoPath, size: "w500")
                }
                // 背景 poster 用 original 走代理
                if let posterPath = images?.bestPoster?.originalURL {
                    tmdbPosterURL = TMDBService.shared.proxiedImageURL(posterPath, size: "original")
                }
                // backdrop 备用
                if let backdropPath = images?.bestBackdrop?.originalURL {
                    tmdbBackdropURL = TMDBService.shared.proxiedImageURL(backdropPath, size: "original")
                }

                // 演职人员：TMDB 有则替换，没有保留豆瓣
                if let credits, !credits.actors.isEmpty {
                    actors = credits.actors
                    directors = credits.directors
                    writers = credits.writers
                }
                // 如果 TMDB 没找到任何演职人员，触发豆瓣兜底
                if actors.isEmpty && directors.isEmpty && writers.isEmpty {
                    loadCredits()
                }

                isLoadingTMDB = false
            }
        }
    }

    // MARK: - 网盘
    private func loadPanLinks() {
        guard panLinks.isEmpty, !isLoadingPan else { return }
        isLoadingPan = true
        Task {
            if let result = await SpiderManager.shared.resolveCloudPlay(from: video.vodId) {
                await MainActor.run { panLinks = result.links; isLoadingPan = false }
            } else {
                await MainActor.run { isLoadingPan = false }
            }
        }
    }

    private func playPanLink(_ link: (url: String, name: String)) {
        selectedPanVideo = VodItem(vodId: link.url, vodName: "\(video.vodName) - \(link.name)",
                                    vodPic: video.vodPic, vodRemarks: "☁️网盘", vodPlayUrl: link.url)
    }

    // MARK: - 播放
    private func handlePlay() {
        if isCloudVideo {
            if !panLinks.isEmpty {
                playPanLink(panLinks[0])
            } else if !isLoadingPan {
                isLoadingPan = true
                Task {
                    if let result = await SpiderManager.shared.resolveCloudPlay(from: video.vodId) {
                        await MainActor.run {
                            panLinks = result.links; isLoadingPan = false
                            if let first = panLinks.first { playPanLink(first) }
                        }
                    } else { await MainActor.run { isLoadingPan = false } }
                }
            }
        } else { showPlayer = true }
    }

    // MARK: - 分享
    private func handleShare() {
        let text = "\(displayVideo.vodName)\n\(displayVideo.vodContent ?? "")"
        let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(activityVC, animated: true)
        }
    }

    // MARK: - 收藏
    private func checkFavorite() {
        let sourceName = allSources.first?.name ?? ""
        if let favId = DatabaseManager.shared.isFavorite2(detailurl: video.vodId, laiyuan: sourceName) {
            isFavorite = true
            favoriteId = favId
        } else {
            isFavorite = false
            favoriteId = nil
        }
    }

    private func toggleFavorite() {
        if isFavorite, let favId = favoriteId {
            DatabaseManager.shared.removeFavorite(id: favId)
            isFavorite = false
            favoriteId = nil
        } else {
            let sourceName = allSources.first?.name ?? ""
            let record = FavoriteRecord(
                name: displayVideo.vodName,
                laiyuan: sourceName,
                imgurl: displayVideo.vodPic ?? "",
                detailurl: video.vodId,
                detailua: "",
                xianlu: 0,
                jishu: 0,
                addedAt: Int64(Date().timeIntervalSince1970)
            )
            DatabaseManager.shared.addFavorite(record)
            isFavorite = true
            // 重新查询获取 id
            if let favId = DatabaseManager.shared.isFavorite2(detailurl: video.vodId, laiyuan: sourceName) {
                favoriteId = favId
            }
        }
    }

    // MARK: - 下载
    private func handleDownload() {
        guard !episodes.isEmpty else {
            showDownloadTip = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showDownloadTip = false }
            return
        }
        let episode = episodes[0]
        let sourceName = allSources.first?.name ?? ""
        let record = DownloadRecord(
            name: "\(displayVideo.vodName) \(episode.name)",
            laiyuan: sourceName,
            imgurl: displayVideo.vodPic ?? "",
            detailurl: video.vodId,
            playurl: episode.url,
            jishu: 1,
            progress: 0,
            status: "pending",
            addedAt: Int64(Date().timeIntervalSince1970)
        )
        DatabaseManager.shared.addDownload(record)
        showDownloadTip = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showDownloadTip = false }
    }

    // MARK: - 选集
    private func handleEpisodeSelect(_ episode: (name: String, url: String)) {
        selectedEpisodeVideo = VodItem(
            vodId: displayVideo.vodId,
            vodName: "\(displayVideo.vodName) \(episode.name)",
            vodPic: displayVideo.vodPic,
            vodRemarks: episode.name,
            vodYear: displayVideo.vodYear,
            vodArea: displayVideo.vodArea,
            vodDirector: displayVideo.vodDirector,
            vodActor: displayVideo.vodActor,
            vodContent: displayVideo.vodContent,
            vodPlayFrom: displayVideo.vodPlayFrom,
            vodPlayUrl: episode.url
        )
    }

    // MARK: - 解析播放源
    private func parseAllSources(from raw: String?, playFrom: String?) -> [(name: String, episodes: [(name: String, url: String)])] {
        guard let raw, !raw.isEmpty else { return [] }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            guard let data = trimmed.data(using: .utf8),
                  let links = try? JSONSerialization.jsonObject(with: data) as? [[String: String]],
                  !links.isEmpty else { return [] }
            var episodes: [(name: String, url: String)] = []
            for (idx, link) in links.enumerated() {
                guard let url = link["url"], !url.isEmpty else { continue }
                let name = link["name"] ?? "网盘资源\(idx + 1)"
                episodes.append((name: name, url: url))
            }
            guard !episodes.isEmpty else { return [] }
            return [("网盘资源", episodes)]
        }

        let urlGroups = raw.components(separatedBy: "$$$")
        let nameGroups = playFrom?.components(separatedBy: "$$$") ?? []

        var sources: [(name: String, episodes: [(name: String, url: String)])] = []
        for (idx, group) in urlGroups.enumerated() {
            let eps = parseGroupEpisodes(group)
            guard !eps.isEmpty else { continue }
            let sourceName = (idx < nameGroups.count && !nameGroups[idx].isEmpty) ? nameGroups[idx] : "线路\(idx + 1)"
            sources.append((name: sourceName, episodes: eps))
        }
        sources.sort { a, b in
            let aIsM3u8 = a.name.lowercased().contains("m3u8")
            let bIsM3u8 = b.name.lowercased().contains("m3u8")
            let aIsYun = a.name.lowercased().contains("yun")
            let bIsYun = b.name.lowercased().contains("yun")
            if aIsM3u8 && !bIsM3u8 { return true }
            if !aIsM3u8 && bIsM3u8 { return false }
            if aIsYun && !bIsYun { return false }
            if !aIsYun && bIsYun { return true }
            return false
        }
        return sources
    }

    private func parseGroupEpisodes(_ group: String) -> [(name: String, url: String)] {
        group.components(separatedBy: "#").compactMap { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let pieces = trimmed.components(separatedBy: "$")
            if pieces.count >= 2 {
                return (name: pieces[0].isEmpty ? "播放" : pieces[0], url: pieces[1])
            }
            if trimmed.hasPrefix("http") || trimmed.contains("pan.baidu.com") {
                return (name: "播放", url: trimmed)
            }
            return nil
        }
    }

    private func driveColor(_ name: String) -> Color {
        if name.contains("115") { return .orange }
        if name.contains("阿里") { return .blue }
        if name.contains("夸克") { return .purple }
        if name.contains("百度") { return .green }
        if name.contains("UC") { return .red }
        return .gray
    }

    // MARK: - Body
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // MARK: 全屏背景（TMDB poster 优先 > 蓝调深色渐变）
                Group {
                    if let poster = tmdbPosterURL,
                       let url = URL(string: poster) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .clipped()
                            default:
                                fallbackBackground
                            }
                        }
                    } else {
                        fallbackBackground
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .ignoresSafeArea()

                // MARK: 可滚动内容 + logo（一起滚动）
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // 顶部 hero 区域：logo 直接透底
                        VStack(spacing: 12) {
                            Spacer()
                                .frame(height: geometry.safeAreaInsets.top + 20)

                            HeroTitleView(
                                name: displayVideo.vodName,
                                logoURL: tmdbLogoURL
                            )
                            .frame(maxHeight: 70)

                            Text(displayVideo.vodName)
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)

                            HStack(spacing: 8) {
                                Text("剧情")
                                    .font(.system(size: 11))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .foregroundColor(.white.opacity(0.9))

                                if let year = displayVideo.vodYear, !year.isEmpty {
                                    Text(year)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.85))
                                }
                            }

                            Spacer()
                        }
                        .frame(height: geometry.size.height * 0.42)

                        // 内容区
                        VStack(spacing: 20) {
                            // 立即播放按钮
                            Button(action: handlePlay) {
                                HStack(spacing: 8) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                    Text("立即播放")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                                .foregroundColor(.black)
                                .frame(maxWidth: min(UIScreen.main.bounds.width - 120, 300))
                                .padding(.vertical, 14)
                                .background(Color(hex: "93C5FD"))
                                .cornerRadius(28)
                            }
                            .buttonStyle(.plain)

                            // 演职人员分类展示
                            if !actors.isEmpty || !directors.isEmpty || !writers.isEmpty || isLoadingCredits {
                                VStack(alignment: .leading, spacing: 12) {
                                    // 分类标签
                                    HStack(spacing: 12) {
                                        ForEach(["全部", "演员", "导演", "编剧"], id: \.self) { tab in
                                            let available: Bool = {
                                                switch tab {
                                                case "全部": return !actors.isEmpty || !directors.isEmpty || !writers.isEmpty
                                                case "演员": return !actors.isEmpty
                                                case "导演": return !directors.isEmpty
                                                case "编剧": return !writers.isEmpty
                                                default: return false
                                                }
                                            }()
                                            if available {
                                                Button(action: { selectedCastTab = tab }) {
                                                    Text(tab)
                                                        .font(.system(size: 14, weight: selectedCastTab == tab ? .semibold : .medium))
                                                        .foregroundColor(selectedCastTab == tab ? .white : .white.opacity(0.6))
                                                        .padding(.horizontal, 12)
                                                        .padding(.vertical, 6)
                                                        .background(selectedCastTab == tab ? Color.white.opacity(0.2) : Color.clear)
                                                        .cornerRadius(6)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                    }

                                    // 当前分类人员
                                    let currentPeople: [DoubanCelebrity] = {
                                        switch selectedCastTab {
                                        case "全部": return actors + directors + writers
                                        case "导演": return directors
                                        case "编剧": return writers
                                        default: return actors
                                        }
                                    }()

                                    if !currentPeople.isEmpty {
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 14) {
                                                ForEach(currentPeople, id: \.id) { person in
                                                    CastPersonCard(person: person)
                                                }
                                            }
                                        }
                                    } else {
                                        Text("暂无\(selectedCastTab)信息")
                                            .font(.system(size: 12))
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                }
                            }

                            // 剧情简介
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("剧情简介")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                    Spacer()
                                    Button(action: toggleFavorite) {
                                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                                            .font(.system(size: 24))
                                            .foregroundColor(isFavorite ? Color(hex: "E11D48") : .white.opacity(0.9))
                                    }
                                    .buttonStyle(.plain)
                                }
                                Text(displayVideo.vodContent ?? "暂无简介")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white.opacity(0.75))
                                    .lineSpacing(4)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // 网盘资源
                            if isCloudVideo {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Image(systemName: "cloud.fill").font(.system(size: 14)).foregroundColor(.blue)
                                        if isLoadingPan {
                                            Text("正在加载网盘资源...").font(.system(size: 14)).foregroundColor(.gray)
                                            Spacer(); ProgressView().scaleEffect(0.8)
                                        } else if panLinks.isEmpty {
                                            Text("未找到网盘链接").font(.system(size: 14)).foregroundColor(.gray)
                                        } else {
                                            Text("网盘资源 (\(panLinks.count) 个)").font(.system(size: 14, weight: .semibold)).foregroundColor(.blue)
                                        }
                                        Spacer()
                                    }
                                    if !isLoadingPan, !panLinks.isEmpty {
                                        ForEach(Array(panLinks.enumerated()), id: \.offset) { _, link in
                                            Button(action: { playPanLink(link) }) {
                                                HStack(spacing: 10) {
                                                    Image(systemName: "link.circle.fill").font(.system(size: 16)).foregroundColor(driveColor(link.name))
                                                    Text(link.name).font(.system(size: 13)).foregroundColor(.white)
                                                    Spacer()
                                                    Text("点击播放").font(.system(size: 11)).foregroundColor(Color(hex: "E11D48"))
                                                }
                                                .padding(10)
                                                .background(Color.white.opacity(0.1))
                                                .cornerRadius(8)
                                            }.buttonStyle(PlainButtonStyle())
                                        }
                                    }
                                }.padding(.vertical, 8)
                            }

                            // 多线路切换 + 剧集网格
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("剧集列表")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                    Spacer()
                                    if isLoadingDetail {
                                        ProgressView().scaleEffect(0.8)
                                    } else {
                                        Text(episodes.isEmpty ? "暂无真实剧集" : "共 \(episodes.count) 集")
                                            .font(.system(size: 12))
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                }

                                if allSources.count > 1 {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(Array(allSources.enumerated()), id: \.offset) { idx, source in
                                                Button(action: { selectedSourceIndex = idx }) {
                                                    Text(source.name)
                                                        .font(.system(size: 12, weight: idx == selectedSourceIndex ? .semibold : .medium))
                                                        .foregroundColor(idx == selectedSourceIndex ? .white : .white.opacity(0.8))
                                                        .padding(.horizontal, 12)
                                                        .padding(.vertical, 6)
                                                        .background(
                                                            RoundedRectangle(cornerRadius: 8)
                                                                .fill(idx == selectedSourceIndex ? Color(hex: "E11D48") : Color.white.opacity(0.12))
                                                        )
                                                }.buttonStyle(PlainButtonStyle())
                                            }
                                        }
                                    }
                                }

                                EpisodeGridView(episodes: episodes) { episode in
                                    handleEpisodeSelect(episode)
                                }
                            }.padding(.top, 8)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                        .padding(.bottom, 120)
                        // 内容区背景：毛玻璃 + 极淡黑色叠加，直接透出底层封面图
                        .background(
                            ZStack {
                                .ultraThinMaterial
                                Color.black.opacity(0.08)
                            }
                            .ignoresSafeArea(edges: .bottom)
                        )
                    }
                }
                .ignoresSafeArea()

                // MARK: - 底部悬浮操作栏（胶囊样式，类似首页底栏）
            VStack(spacing: 0) {
                Spacer()
                HStack(spacing: 0) {
                    BottomBarButton(icon: "play.fill", title: "播放") { handlePlay() }
                    BottomBarButton(icon: "list.bullet", title: "选集") { showEpisodeSheet = true }
                    BottomBarButton(icon: "square.and.arrow.down", title: "下载") { handleDownload() }
                    BottomBarButton(icon: "square.and.arrow.up", title: "分享") { handleShare() }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: min(UIScreen.main.bounds.width - 120, 300))
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .background(Capsule().fill(settings.usesLiquidSkin ? Color(hex: "1A1A2E").opacity(0.85) : Color.black.opacity(0.6)))
                        .overlay(
                            Capsule().stroke(settings.usesFrostedSkin ? Color(uiColor: .separator) : Color.white.opacity(0.15), lineWidth: 1)
                        )
                )
                .clipShape(Capsule())
                .padding(.bottom, 20)
            }

            // 下载提示
            if showDownloadTip {
                VStack {
                    Spacer()
                    Text(episodes.isEmpty ? "暂无播放源，无法下载" : "已添加到下载列表")
                        .font(.system(size: 14))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Color.black.opacity(0.75)))
                        .foregroundColor(.white)
                        .padding(.bottom, 100)
                }
                .transition(.opacity)
                .animation(.easeInOut, value: showDownloadTip)
            }
        }
        // 播放器
        .fullScreenCover(isPresented: $showPlayer) { VideoPlayerViewV2(video: video) }
        .fullScreenCover(item: $selectedPanVideo) { panVideo in VideoPlayerViewV2(video: panVideo) }
        .fullScreenCover(item: $selectedEpisodeVideo) { epVideo in VideoPlayerViewV2(video: epVideo) }
        // 选集弹窗（半屏）
        .sheet(isPresented: $showEpisodeSheet) {
            EpisodeSheetView(
                sources: allSources,
                selectedSourceIndex: $selectedSourceIndex,
                onSelect: { episode in
                    handleEpisodeSelect(episode)
                    showEpisodeSheet = false
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            initializeSources()
            if isCloudVideo { loadPanLinks() }
            loadRealDetailIfNeeded()
            loadCredits()
            loadTMDBData()
            checkFavorite()
        }
        .edgeSwipeBack { dismiss() }
    }
}
}

// MARK: - 大标题视图（TMDB logo 优先，马善政毛笔楷体兜底）
struct HeroTitleView: View {
    let name: String
    let logoURL: String?

    var body: some View {
        if let logoURL = logoURL,
           let url = URL(string: logoURL) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 70)
                default:
                    fallbackTitle
                }
            }
        } else {
            fallbackTitle
        }
    }

    private var fallbackTitle: some View {
        Text(name)
            .font(.custom("Ma Shan Zheng", size: 48))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 2)
    }
}

// MARK: - 演职人员卡片
struct CastPersonCard: View {
    let person: DoubanCelebrity

    var body: some View {
        VStack(spacing: 6) {
            AsyncImage(url: DoubanImageProxyServer.shared.resolvedURL(for: person.avatarURL)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                default:
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 60, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(person.name)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(width: 60)

            if let role = person.character ?? person.roles?.first {
                Text(role)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(width: 60)
            }
        }
    }
}

// MARK: - 底部栏按钮
struct BottomBarButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")], startPoint: .top, endPoint: .bottom))
                Text(title)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 选集弹窗
struct EpisodeSheetView: View {
    let sources: [(name: String, episodes: [(name: String, url: String)])]
    @Binding var selectedSourceIndex: Int
    let onSelect: ((name: String, url: String)) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 线路切换
                if sources.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(sources.enumerated()), id: \.offset) { idx, source in
                                Button(action: { selectedSourceIndex = idx }) {
                                    Text(source.name)
                                        .font(.system(size: 13, weight: idx == selectedSourceIndex ? .semibold : .medium))
                                        .foregroundColor(idx == selectedSourceIndex ? .white : .primary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(idx == selectedSourceIndex ? Color(hex: "E11D48") : Color(uiColor: .secondarySystemGroupedBackground))
                                        )
                                }.buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    Divider().padding(.horizontal, 16)
                }

                // 集数列表
                ScrollView {
                    let currentEpisodes = selectedSourceIndex < sources.count ? sources[selectedSourceIndex].episodes : []
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                        ForEach(Array(currentEpisodes.enumerated()), id: \.offset) { _, episode in
                            Button(action: { onSelect(episode) }) {
                                Text(episode.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                                    .cornerRadius(10)
                            }.buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 演职人员区块
struct CreditsSection: View {
    let actors: [DoubanCelebrity]
    let directors: [DoubanCelebrity]
    let writers: [DoubanCelebrity]
    let isLoading: Bool
    @State private var selectedTab = 0
    private let tabs = ["全部", "主演", "导演", "编剧"]

    private var displayList: [DoubanCelebrity] {
        switch selectedTab {
        case 1: return actors
        case 2: return directors
        case 3: return writers
        default: return actors + directors + writers
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("演职人员").font(.system(size: 16, weight: .semibold)).foregroundColor(.primary)

            // Tab 切换
            HStack(spacing: 16) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { idx, tab in
                    Button(action: { selectedTab = idx }) {
                        Text(tab)
                            .font(.system(size: 14, weight: selectedTab == idx ? .semibold : .medium))
                            .foregroundColor(selectedTab == idx ? Color(hex: "E11D48") : .gray)
                    }.buttonStyle(PlainButtonStyle())
                }
                Spacer()
            }

            if isLoading && displayList.isEmpty {
                HStack {
                    Spacer()
                    ProgressView().scaleEffect(0.8)
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if displayList.isEmpty {
                Text("暂无演职人员信息")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
                    .padding(.vertical, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(displayList) { person in
                            VStack(spacing: 6) {
                                // 演员封面图 - 小长方形圆角样式
                                if let url = DoubanImageProxyServer.shared.resolvedURL(for: person.avatarURL) {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                        case .failure, .empty:
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(Color.gray.opacity(0.25))
                                                .overlay(
                                                    Image(systemName: "person.fill")
                                                        .font(.system(size: 24))
                                                        .foregroundColor(.gray.opacity(0.6))
                                                )
                                        @unknown default:
                                            EmptyView()
                                        }
                                    }
                                    .frame(width: 76, height: 100)
                                    .cornerRadius(6)
                                } else {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.gray.opacity(0.25))
                                        .frame(width: 76, height: 100)
                                        .overlay(
                                            Image(systemName: "person.fill")
                                                .font(.system(size: 24))
                                                .foregroundColor(.gray.opacity(0.6))
                                        )
                                }

                                Text(person.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                    .frame(width: 76)

                                if !person.roleText.isEmpty {
                                    Text(person.roleText)
                                        .font(.system(size: 10))
                                        .foregroundColor(.gray)
                                        .lineLimit(1)
                                        .frame(width: 76)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - 辅助组件
struct TagLabel: View {
    let text: String
    var body: some View {
        if !text.isEmpty {
            Text(text).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.7))
                .clipShape(Capsule())
        }
    }
}

struct ActionButton: View {
    let icon: String; let title: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(LinearGradient(colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")], startPoint: .top, endPoint: .bottom))
                Text(title).font(.system(size: 12)).foregroundColor(.primary)
            }.frame(maxWidth: .infinity)
        }.buttonStyle(PlainButtonStyle())
    }
}

struct EpisodeGridView: View {
    @State private var selectedEpisode = 1
    let episodes: [(name: String, url: String)]
    let onSelect: ((name: String, url: String)) -> Void
    var body: some View {
        if episodes.isEmpty {
            Text("当前资源暂未解析到真实剧集列表")
                .font(.system(size: 13))
                .foregroundColor(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(Array(episodes.enumerated()), id: \.offset) { idx, episode in
                    let ep = idx + 1
                    Button(action: {
                        selectedEpisode = ep
                        onSelect(episode)
                    }) {
                        Text(episode.name).font(.system(size: 13, weight: ep == selectedEpisode ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .foregroundColor(ep == selectedEpisode ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(ep == selectedEpisode ? Color(hex: "E11D48") : Color(uiColor: .secondarySystemGroupedBackground).opacity(0.8))
                            )
                    }.buttonStyle(PlainButtonStyle())
                }
            }
        }
    }
}
