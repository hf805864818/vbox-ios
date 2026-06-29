import SwiftUI

struct ShortDramaDetailView: View {
    let drama: VodItem
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var dramaService = ShortDramaService.shared
    @State private var detailItem: VodItem?
    @State private var episodes: [(number: String, url: String)] = []
    @State private var isLoading = true
    @State private var selectedEpisodeIndex = 0
    @State private var showPlayer = false
    @State private var playerDrama: VodItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    coverInfoSection
                    synopsisSection
                    episodesSection
                    playButtonSection
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
            .fullScreenCover(isPresented: $showPlayer) {
                if let playDrama = playerDrama {
                    VideoDetailView(video: playDrama)
                }
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
        AsyncImage(url: URL(string: detailItem?.vodPic ?? drama.vodPic)) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .failure:
                ZStack {
                    Color.gray.opacity(0.2)
                    Image(systemName: "play.slash")
                        .foregroundColor(.gray)
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

                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 70, maximum: 90), spacing: 10)
                ], spacing: 10) {
                    ForEach(Array(episodes.enumerated()), id: \.offset) { index, ep in
                        Button(action: {
                            selectedEpisodeIndex = index
                            let ep = episodes[index]
                            let playItem = VodItem(
                                vodId: drama.vodId,
                                vodName: drama.vodName,
                                vodPic: detailItem?.vodPic ?? drama.vodPic,
                                vodPlayFrom: detailItem?.vodPlayFrom ?? drama.vodPlayFrom,
                                vodPlayUrl: ep.url
                            )
                            playerDrama = playItem
                            showPlayer = true
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
            }
        } else if !isLoading {
            Text("暂无播放地址")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private var playButtonSection: some View {
        if !episodes.isEmpty {
            Button(action: {
                let ep = episodes[selectedEpisodeIndex]
                let playItem = VodItem(
                    vodId: drama.vodId,
                    vodName: drama.vodName,
                    vodPic: detailItem?.vodPic ?? drama.vodPic,
                    vodPlayFrom: detailItem?.vodPlayFrom ?? drama.vodPlayFrom,
                    vodPlayUrl: ep.url
                )
                playerDrama = playItem
                showPlayer = true
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
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private func loadDetail() {
        parseEpisodes(from: drama.vodPlayUrl)

        if episodes.isEmpty || (detailItem?.vodContent?.isEmpty ?? true) {
            Task {
                for source in dramaService.shortDramaSources {
                    if let detail = await dramaService.fetchDetail(vodId: drama.vodId, api: source.api) {
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

    private func parseEpisodes(from playUrl: String?) {
        guard let url = playUrl, !url.isEmpty else { return }

        if url.contains("#") {
            let parts = url.components(separatedBy: "#")
            episodes = parts.compactMap { part -> (String, String)? in
                let split = part.components(separatedBy: "$")
                guard split.count >= 2 else { return nil }
                let number = split[0].trimmingCharacters(in: .whitespaces)
                let videoUrl = split[1].trimmingCharacters(in: .whitespaces)
                guard !videoUrl.isEmpty else { return nil }
                return (number, videoUrl)
            }
        } else if url.contains("$") {
            let split = url.components(separatedBy: "$")
            if split.count >= 2 {
                let videoUrl = split[1].trimmingCharacters(in: .whitespaces)
                if !videoUrl.isEmpty {
                    episodes = [(split[0].trimmingCharacters(in: .whitespaces), videoUrl)]
                }
            }
        } else if url.hasPrefix("http") {
            episodes = [("播放", url)]
        }
    }

    private var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }
}
