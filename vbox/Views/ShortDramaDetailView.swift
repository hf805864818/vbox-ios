import SwiftUI

struct ShortDramaDetailView: View {
    let drama: VodItem
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var dramaService = ShortDramaService.shared
    @State private var detailItem: VodItem?
    @State private var episodes: [(number: String, url: String)] = []
    @State private var isLoading = true
    @State private var selectedEpisodeIndex = 0
    @State private var playerDrama: VodItem?
    @State private var showDownloadSheet = false
    @State private var showDownloadTip = false
    @State private var downloadTipText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    coverInfoSection
                    synopsisSection
                    episodesSection
                    actionButtonsSection
                }
                .padding(.bottom, 40)
            }
            .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
            .navigationTitle("短剧详情")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if isLoading {
                    ProgressView()
                }
            }
            .overlay(alignment: .bottom) {
                if showDownloadTip {
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
            .fullScreenCover(item: $playerDrama) { playDrama in
                VideoPlayerViewV2(video: playDrama, preParsedEpisodes: episodes.isEmpty ? nil : episodes.map { (name: $0.number, url: $0.url) })
            }
            .sheet(isPresented: $showDownloadSheet) {
                ShortDramaDownloadSheet(
                    episodes: episodes,
                    onSelect: { indices in
                        handleBatchDownload(indices: indices)
                        showDownloadSheet = false
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .onAppear {
                loadDetail()
            }
        }
    }

    @ViewBuilder
    private var coverInfoSection: some View {
        HStack(alignment: .top, spacing: 16) {
            coverImage
            metadataVStack
        }
        .padding(.horizontal, 16)
    }

    private var coverImage: some View {
        AsyncImage(url: DoubanImageProxyServer.shared.resolvedURL(for: detailItem?.vodPic ?? drama.vodPic)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failure:
                ZStack {
                    Color.gray.opacity(0.2)
                    VStack(spacing: 4) {
                        Image(systemName: "play.slash")
                            .foregroundColor(.gray)
                        Text("加载失败")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                }
            case .empty:
                ZStack {
                    Color.gray.opacity(0.1)
                    ProgressView()
                }
            @unknown default:
                Color.gray.opacity(0.2)
            }
        }
        .frame(width: 120, height: 170)
        .clipped()
        .cornerRadius(8)
    }

    private var metadataVStack: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(drama.vodName)
                .font(.system(size: 18, weight: .bold))
                .lineLimit(2)

            if let remarks = drama.vodRemarks {
                Label(remarks, systemImage: "clock")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            if let year = detailItem?.vodYear ?? drama.vodYear {
                Label(year, systemImage: "calendar")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            if let actor = detailItem?.vodActor ?? drama.vodActor, !actor.isEmpty {
                Label(actor, systemImage: "person")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var synopsisSection: some View {
        if let content = detailItem?.vodContent ?? drama.vodContent, !content.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("剧情简介")
                    .font(.system(size: 15, weight: .semibold))
                Text(content)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(5)
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var episodesSection: some View {
        if !episodes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("选集 (\(episodes.count)集)")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 16)

                ScrollView(.vertical, showsIndicators: true) {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 70, maximum: 90), spacing: 10)
                    ], spacing: 10) {
                        ForEach(Array(episodes.enumerated()), id: \.offset) { index, ep in
                            Button(action: {
                                selectedEpisodeIndex = index
                                let ep = episodes[index]
                                playerDrama = VodItem(
                                    vodId: drama.vodId,
                                    vodName: "\(drama.vodName) \(ep.number)",
                                    vodPic: detailItem?.vodPic ?? drama.vodPic,
                                    vodRemarks: ep.number,
                                    vodYear: detailItem?.vodYear ?? drama.vodYear,
                                    vodArea: detailItem?.vodArea ?? drama.vodArea,
                                    vodDirector: detailItem?.vodDirector ?? drama.vodDirector,
                                    vodActor: detailItem?.vodActor ?? drama.vodActor,
                                    vodContent: detailItem?.vodContent ?? drama.vodContent,
                                    vodPlayFrom: detailItem?.vodPlayFrom ?? drama.vodPlayFrom,
                                    vodPlayUrl: detailItem?.vodPlayUrl ?? drama.vodPlayUrl,
                                    engineKey: detailItem?.engineKey ?? drama.engineKey
                                )
                            }) {
                                Text(ep.number)
                                    .font(.system(size: 13, weight: .medium))
                                    .frame(width: 70, height: 36)
                                    .background(selectedEpisodeIndex == index ? accentColor : Color.gray.opacity(0.12))
                                    .foregroundColor(selectedEpisodeIndex == index ? .white : .primary)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 200)
            }
        } else if !isLoading {
            Text("暂无播放地址")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var actionButtonsSection: some View {
        if !episodes.isEmpty {
            HStack(spacing: 12) {
                // 播放按钮
                Button(action: {
                    let ep = episodes[selectedEpisodeIndex]
                    playerDrama = VodItem(
                        vodId: drama.vodId,
                        vodName: "\(drama.vodName) \(ep.number)",
                        vodPic: detailItem?.vodPic ?? drama.vodPic,
                        vodRemarks: ep.number,
                        vodYear: detailItem?.vodYear ?? drama.vodYear,
                        vodArea: detailItem?.vodArea ?? drama.vodArea,
                        vodDirector: detailItem?.vodDirector ?? drama.vodDirector,
                        vodActor: detailItem?.vodActor ?? drama.vodActor,
                        vodContent: detailItem?.vodContent ?? drama.vodContent,
                        vodPlayFrom: detailItem?.vodPlayFrom ?? drama.vodPlayFrom,
                        vodPlayUrl: detailItem?.vodPlayUrl ?? drama.vodPlayUrl,
                        engineKey: detailItem?.engineKey ?? drama.engineKey
                    )
                }) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("立即播放")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(accentColor)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)

                // 下载按钮
                Button(action: {
                    showDownloadSheet = true
                }) {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                        Text("下载")
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.gray.opacity(0.6))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private func loadDetail() {
        parseEpisodes(from: drama.vodPlayUrl)

        if episodes.isEmpty || (detailItem?.vodContent?.isEmpty ?? true) {
            Task {
                let sources: [ShortDramaSource]
                if let engineKey = drama.engineKey {
                    sources = dramaService.shortDramaSources.filter { $0.engineKey == engineKey }
                        + dramaService.shortDramaSources.filter { $0.engineKey != engineKey }
                } else {
                    sources = dramaService.shortDramaSources.filter { $0.engineKey == nil }
                        + dramaService.shortDramaSources.filter { $0.engineKey != nil }
                }

                for source in sources {
                    if let detail = await dramaService.fetchDetail(vodId: drama.vodId, api: source.api, engineKey: source.engineKey) {
                        await MainActor.run {
                            detailItem = detail
                            parseEpisodes(from: detail.vodPlayUrl)
                            isLoading = false
                        }
                        return
                    }
                }
                await MainActor.run { isLoading = false }
            }
        } else {
            isLoading = false
        }
    }

    // MARK: - 批量下载
    private func handleBatchDownload(indices: [Int]) {
        guard !episodes.isEmpty, !indices.isEmpty else { return }

        let sourceName = "短剧"
        let engineKey = detailItem?.engineKey ?? drama.engineKey

        for index in indices {
            guard index < episodes.count else { continue }
            let episode = episodes[index]

            let record = DownloadRecord(
                name: "\(drama.vodName) \(episode.number)",
                laiyuan: sourceName,
                imgurl: detailItem?.vodPic ?? drama.vodPic,
                detailurl: drama.vodId,
                playurl: episode.url,
                jishu: index + 1,
                progress: 0,
                status: "pending",
                addedAt: Int64(Date().timeIntervalSince1970),
                sourceType: "normal",
                engineKey: engineKey,
                vodId: drama.vodId
            )
            DownloadManager.shared.enqueueDownload(record: record)
        }

        downloadTipText = "已添加 \(indices.count) 集到下载"
        showDownloadTip = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showDownloadTip = false }
    }

    private func parseEpisodes(from playUrl: String?) {
        guard let url = playUrl, !url.isEmpty else { return }

        // 方式1：标准格式 - $$$ 分隔线路，# 分隔集（取第一条线路）
        let standardResult = parseStandardFormat(playUrl: url)

        // 方式2：非标准格式 - $$$ 直接分隔集（某些源用 $$$ 而不是 # 分集）
        let dollar3Result = parseDollar3AsEpisodes(playUrl: url)

        // 智能选择逻辑：
        // 1. 没有 $$$ 分隔 → 直接用标准格式
        // 2. $$$ 分隔但每块都像集名（包含"第X集/第X话"等模式）→ 用 $$$ 方式
        // 3. $$$ 分隔但块名像线路名（高清/备用/线路等）→ 用标准格式
        // 4. 无法判断时，集数差距大（>2倍）且集数多的优先
        guard url.contains("$$$") else {
            episodes = standardResult
            return
        }

        let dollar3LooksLikeEpisodes = dollar3Result.allSatisfy { looksLikeEpisodeName($0.0) }
        let dollar3LooksLikeLines = dollar3Result.allSatisfy { isLineName($0.0) }
        let standardLooksLikeLines = standardResult.allSatisfy { isLineName($0.0) }

        // 2. $$$ 块名明显像集名，且标准格式只能解析出1集或更少 → 用 $$$ 方式
        // （如果标准格式能解析出>1集，说明线路内用#分隔了多集，是标准VOD格式）
        if dollar3LooksLikeEpisodes && dollar3Result.count > standardResult.count && standardResult.count <= 1 {
            episodes = dollar3Result
            return
        }

        // $$$ 块名明显像线路名 → 用标准格式
        if dollar3LooksLikeLines {
            episodes = standardResult
            return
        }

        // 标准格式结果像线路名（集数少且名字像线路） → 尝试 $$$ 方式
        if standardLooksLikeLines && standardResult.count <= 5 && dollar3Result.count > standardResult.count {
            episodes = dollar3Result
            return
        }

        // 集数差距很大（>3倍）时选集数多的
        if dollar3Result.count > standardResult.count * 3 && dollar3Result.count > 5 {
            episodes = dollar3Result
            return
        }

        // 默认用标准格式
        episodes = standardResult
    }

    /// 判断名称是否像线路名（而非集数名）
    private func isLineName(_ name: String) -> Bool {
        let lineKeywords = ["线路", "高清", "标清", "超清", "蓝光", "备用", "播放", "云播", "极速", "流畅", "1080", "720", "4k", "原画", "云", "播放源", "资源"]
        return lineKeywords.contains { name.lowercased().contains($0.lowercased()) }
    }

    /// 判断名称是否像集数名
    private func looksLikeEpisodeName(_ name: String) -> Bool {
        // 匹配 "第X集"、"第X话"、"第X期"、"EPX"、"第X章" 等模式
        let patterns = [
            "^第\\d+[集话期章部季]?$",
            "^\\d+$",
            "^EP\\d+$",
            "^ep\\d+$",
            "^第[一二三四五六七八九十百千零\\d]+集$"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil {
                return true
            }
        }
        return false
    }

    /// 标准格式解析：$$$ 分隔线路，# 分隔集，$ 分隔集名和URL
    private func parseStandardFormat(playUrl: String) -> [(String, String)] {
        let episodePart: String
        if playUrl.contains("$$$") {
            episodePart = playUrl.components(separatedBy: "$$$").first ?? playUrl
        } else {
            episodePart = playUrl
        }

        var result: [(String, String)] = []
        if episodePart.contains("#") {
            let parts = episodePart.components(separatedBy: "#")
            result = parts.enumerated().compactMap { idx, part -> (String, String)? in
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                let split = trimmed.components(separatedBy: "$")
                if split.count >= 2 {
                    let number = split[0].trimmingCharacters(in: .whitespaces)
                    let videoUrl = split[1].trimmingCharacters(in: .whitespaces)
                    guard !videoUrl.isEmpty else { return nil }
                    return (number.isEmpty ? "第\(idx + 1)集" : number, videoUrl)
                } else if trimmed.hasPrefix("http") {
                    return ("第\(idx + 1)集", trimmed)
                }
                return nil
            }
        } else if episodePart.contains("$") {
            let split = episodePart.components(separatedBy: "$")
            if split.count >= 2 {
                let videoUrl = split[1].trimmingCharacters(in: .whitespaces)
                if !videoUrl.isEmpty {
                    result = [(split[0].trimmingCharacters(in: .whitespaces), videoUrl)]
                }
            }
        } else if episodePart.hasPrefix("http") {
            result = [("播放", episodePart)]
        }
        return result
    }

    /// 非标准格式解析：$$$ 直接分隔集（每集用 集名$URL 格式）
    private func parseDollar3AsEpisodes(playUrl: String) -> [(String, String)] {
        guard playUrl.contains("$$$") else { return [] }

        let blocks = playUrl.components(separatedBy: "$$$")
        return blocks.enumerated().compactMap { idx, block -> (String, String)? in
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if trimmed.contains("$") {
                let split = trimmed.components(separatedBy: "$")
                if split.count >= 2 {
                    let name = split[0].trimmingCharacters(in: .whitespaces)
                    let url = split[1].trimmingCharacters(in: .whitespaces)
                    guard !url.isEmpty else { return nil }
                    return (name.isEmpty ? "第\(idx + 1)集" : name, url)
                }
            } else if trimmed.hasPrefix("http") {
                return ("第\(idx + 1)集", trimmed)
            }
            return nil
        }
    }

    private var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }
}

// MARK: - 短剧下载选集弹窗
private struct ShortDramaDownloadSheet: View {
    let episodes: [(number: String, url: String)]
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
                    Text("共 \(episodes.count) 集，已选 \(selectedIndices.count) 集")
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
                            Text(ep.number)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 60, height: 36)
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

            // 底部确认按钮
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
