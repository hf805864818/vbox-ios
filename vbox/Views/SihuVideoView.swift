import SwiftUI
import AVKit

// MARK: - 四虎视频主页（分类选择）

struct SihuVideoHomeView: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = SihuVideoService.shared

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                spacing: 12
            ) {
                ForEach(svc.categories) { cat in
                    NavigationLink(destination: SihuVideoCategoryView(
                        category: cat, platform: platform
                    )) {
                        VStack(spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(UIColor.secondarySystemBackground))
                                    .frame(height: 60)
                                Image(systemName: "film.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.accentColor.opacity(0.6))
                            }
                            Text(cat.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 100)
        }
        .navigationTitle("四虎视频")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 四虎视频分类页（视频列表）

struct SihuVideoCategoryView: View {
    let category: SihuCategory
    let platform: YBoxPlatform2
    @StateObject private var svc = SihuVideoService.shared
    @State private var videos: [SihuVideo] = []
    @State private var page = 1
    @State private var isLoading = false
    @State private var hasMore = true

    var body: some View {
        ZStack {
            List {
                ForEach(videos) { video in
                    NavigationLink(destination: SihuVideoDetailView(
                        vodId: video.vodId, title: video.title
                    )) {
                        SihuVideoRow(video: video)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if video == videos.last, hasMore, !isLoading {
                            loadMore()
                        }
                    }
                }

                if isLoading && page > 1 {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)

            if videos.isEmpty && isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(UIColor.systemBackground).opacity(0.8))
            }
        }
        .navigationTitle(category.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if videos.isEmpty { load() }
        }
    }

    private func load() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            let result = await svc.fetchCategory(typeId: category.typeId, page: page)
            await MainActor.run {
                videos = result
                isLoading = false
                hasMore = result.count >= 20
            }
        }
    }

    private func loadMore() {
        guard !isLoading, hasMore else { return }
        isLoading = true
        page += 1
        Task {
            let result = await svc.fetchCategory(typeId: category.typeId, page: page)
            await MainActor.run {
                videos.append(contentsOf: result)
                isLoading = false
                hasMore = result.count >= 20
            }
        }
    }
}

// MARK: - 视频行视图

struct SihuVideoRow: View {
    let video: SihuVideo

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: video.cover)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Rectangle().fill(Color(UIColor.secondarySystemBackground))
                        .overlay { ProgressView().scaleEffect(0.6) }
                }
            }
            .frame(width: 100, height: 68)
            .cornerRadius(8)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(video.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(2)
                    .foregroundColor(.primary)

                if !video.remarks.isEmpty {
                    Text(video.remarks)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 视频详情页（播放源 + 播放器）

struct SihuVideoDetailView: View {
    let vodId: String
    let title: String
    @StateObject private var svc = SihuVideoService.shared
    @State private var playSources: [SihuPlaySource] = []
    @State private var selectedSourceIdx = 0
    @State private var selectedEpIdx = 0
    @State private var isLoading = true
    @State private var playURL: String? = nil
    @State private var player = AVPlayer()
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 0) {
            // 播放器
            ZStack {
                if let url = playURL, isPlaying {
                    VideoPlayer(player: player)
                        .onAppear { player.play() }
                } else {
                    Rectangle()
                        .fill(Color.black)
                        .aspectRatio(16/9, contentMode: .fit)
                        .overlay {
                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "play.slash")
                                    .font(.system(size: 36))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                }
            }
            .background(Color.black)

            // 标题
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 播放源选择
            if playSources.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(playSources.enumerated()), id: \.offset) { idx, source in
                            Button(action: {
                                selectedSourceIdx = idx
                                selectedEpIdx = 0
                                playEpisode()
                            }) {
                                Text(source.name)
                                    .font(.system(size: 13))
                                    .foregroundColor(selectedSourceIdx == idx ? .white : .primary)
                                    .padding(.horizontal, 14).padding(.vertical, 6)
                                    .background(selectedSourceIdx == idx ? Color.accentColor : Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(16)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 4)
            }

            // 剧集列表
            if !playSources.isEmpty {
                let episodes = playSources[selectedSourceIdx].episodes
                Text("选集")
                    .font(.system(size: 13)).foregroundColor(.secondary)
                    .padding(.horizontal, 16).padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                        ForEach(Array(episodes.enumerated()), id: \.offset) { idx, ep in
                            Button(action: {
                                selectedEpIdx = idx
                                playEpisode()
                            }) {
                                Text(ep.name)
                                    .font(.system(size: 13))
                                    .foregroundColor(selectedEpIdx == idx ? .white : .primary)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(selectedEpIdx == idx ? Color.accentColor : Color(UIColor.secondarySystemBackground))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(maxHeight: 300)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if playSources.isEmpty { loadDetail() }
        }
        .onDisappear {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }

    private func loadDetail() {
        isLoading = true
        Task {
            let sources = await svc.fetchDetail(vodId: vodId)
            await MainActor.run {
                playSources = sources
                isLoading = false
                if !sources.isEmpty { playEpisode() }
            }
        }
    }

    private func playEpisode() {
        guard !playSources.isEmpty else { return }
        let episode = playSources[selectedSourceIdx].episodes[selectedEpIdx]
        isLoading = true
        isPlaying = false
        playURL = nil

        Task {
            let url = await svc.fetchPlayURL(playPath: episode.playPath)
            await MainActor.run {
                isLoading = false
                if let url = url, let playURL = URL(string: url) {
                    playURL = url
                    player.replaceCurrentItem(with: AVPlayerItem(url: playURL))
                    isPlaying = true
                }
            }
        }
    }
}