import SwiftUI
import AVKit
import AVFoundation

// MARK: - 视频详情视图
struct VideoDetailView: View {
    let video: VodItem
    @State private var showPlayer = false
    @State private var isFavorite = false
    @State private var panLinks: [(url: String, name: String)] = []
    @State private var isLoadingPan = false
    @State private var selectedPanVideo: VodItem?
    @State private var selectedEpisodeVideo: VodItem?
    @State private var detailVideo: VodItem?
    @State private var isLoadingDetail = false
    @Environment(\.dismiss) private var dismiss

    private var isCloudVideo: Bool { video.vodRemarks?.hasPrefix("☁️") == true }
    private var displayVideo: VodItem { detailVideo ?? video }
    private var episodes: [(name: String, url: String)] { parseEpisodeList(from: displayVideo.vodPlayUrl) }

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

    private func playPanLink(_ link: (url: String, name: String)) {
        selectedPanVideo = VodItem(vodId: link.url, vodName: "\(video.vodName) - \(link.name)",
                                    vodPic: video.vodPic, vodRemarks: "☁️网盘", vodPlayUrl: link.url)
    }

    private func loadRealDetailIfNeeded() {
        guard detailVideo == nil, !isLoadingDetail else { return }
        isLoadingDetail = true
        Task {
            let detail = await SpiderManager.shared.nativeDetail(ids: video.vodId, name: video.vodName)
            await MainActor.run {
                if let detail, detail.vodPlayUrl?.isEmpty == false {
                    detailVideo = detail
                }
                isLoadingDetail = false
            }
        }
    }

    private func parseEpisodeList(from raw: String?) -> [(name: String, url: String)] {
        guard let raw, !raw.isEmpty else { return [] }
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[") { return [] }
        let groups = raw.components(separatedBy: "$$$")
        let bestGroup = groups.max { parseGroupEpisodes($0).count < parseGroupEpisodes($1).count } ?? raw
        return parseGroupEpisodes(bestGroup)
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // 封面
                    ZStack(alignment: .bottomLeading) {
                        AsyncImage(url: DoubanImageProxyServer.shared.resolvedURL(for: video.vodPic)) { phase in
                            switch phase {
                            case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                            default: Rectangle().fill(Color.gray.opacity(0.3))
                            }
                        }.frame(height: 220).clipped()

                        LinearGradient(colors: [.clear, .black.opacity(0.6), .black.opacity(0.95)], startPoint: .top, endPoint: .bottom)

                        Button(action: handlePlay) {
                            ZStack {
                                Circle().fill(Color(hex: "E11D48")).frame(width: 70, height: 70)
                                Image(systemName: "play.fill").font(.system(size: 28, weight: .bold)).foregroundColor(.white).offset(x: 3)
                            }
                        }.padding(16)
                    }

                    // 信息区
                    VStack(alignment: .leading, spacing: 16) {
                        Text(displayVideo.vodName).font(.system(size: 22, weight: .bold)).foregroundColor(.black)
                        HStack(spacing: 12) {
                            TagLabel(text: displayVideo.vodRemarks ?? "")
                            TagLabel(text: displayVideo.vodYear ?? "")
                        }

                        HStack(spacing: 16) {
                            ActionButton(icon: "play.fill", title: "播放") { handlePlay() }
                            ActionButton(icon: "list.bullet", title: "选集") {}
                            ActionButton(icon: "square.and.arrow.down", title: "下载") {}
                            ActionButton(icon: "square.and.arrow.up", title: "分享") {}
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("剧情简介").font(.system(size: 16, weight: .semibold)).foregroundColor(.black)
                            Text(displayVideo.vodContent ?? "暂无简介").font(.system(size: 14)).foregroundColor(.gray).lineSpacing(4)
                        }

                        // 网盘资源展示
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
                                                Text(link.name).font(.system(size: 13)).foregroundColor(.black)
                                                Spacer()
                                                Text("点击播放").font(.system(size: 11)).foregroundColor(Color(hex: "E11D48"))
                                            }.padding(10).background(Color.gray.opacity(0.08)).cornerRadius(8)
                                        }.buttonStyle(PlainButtonStyle())
                                    }
                                }
                            }.padding(.vertical, 8)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("剧集列表").font(.system(size: 16, weight: .semibold)).foregroundColor(.black)
                                Spacer()
                                if isLoadingDetail {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Text(episodes.isEmpty ? "暂无真实剧集" : "共 \(episodes.count) 集").font(.system(size: 12)).foregroundColor(.gray)
                                }
                            }
                            EpisodeGridView(episodes: episodes) { episode in
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
                        }.padding(.top, 8)
                    }.padding(20).padding(.bottom, 100)
                }
            }
            .background(Color.white)
            .ignoresSafeArea()
            // 普通视频 → 新版播放器
            .fullScreenCover(isPresented: $showPlayer) { VideoPlayerViewV2(video: video) }
            // 网盘资源 → 新版播放器（构造 VodItem 传入）
            .fullScreenCover(item: $selectedPanVideo) { panVideo in VideoPlayerViewV2(video: panVideo) }
            .fullScreenCover(item: $selectedEpisodeVideo) { epVideo in VideoPlayerViewV2(video: epVideo) }
            .onAppear {
                if isCloudVideo { loadPanLinks() }
                loadRealDetailIfNeeded()
            }

        }
        .edgeSwipeBack { dismiss() }
    }
}

// MARK: - 辅助组件
struct TagLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundColor(.gray)
            .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

struct ActionButton: View {
    let icon: String; let title: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(LinearGradient(colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")], startPoint: .top, endPoint: .bottom))
                Text(title).font(.system(size: 12)).foregroundColor(.black)
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
                            .foregroundColor(ep == selectedEpisode ? .white : .black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(ep == selectedEpisode ? Color(hex: "E11D48") : Color.gray.opacity(0.1)))
                    }.buttonStyle(PlainButtonStyle())
                }
            }
        }
    }
}
