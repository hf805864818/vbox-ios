import SwiftUI

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
    @State private var showEpisodeSheet = false

    var body: some View {
        VStack(spacing: 16) {
            AsyncImage(url: URL(string: video.vodPic)) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fit).cornerRadius(12)
                } else {
                    Rectangle().fill(Color.gray.opacity(0.2))
                        .aspectRatio(16/9, contentMode: .fit).cornerRadius(12)
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .center) {
                if isLoading {
                    ProgressView().scaleEffect(2).tint(.white)
                } else if errorMsg != nil {
                    EmptyView()
                } else if detail?.episodes.isEmpty == false {
                    Button(action: { playFirst() }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 60)).foregroundColor(.white.opacity(0.9))
                    }
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
                        Button(action: { playFirst() }) {
                            HStack {
                                Image(systemName: "play.fill")
                                Text(detail.episodes.count == 1 ? "立即播放" : "播放第1集")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 28).padding(.vertical, 10)
                            .background(Color.accentColor).cornerRadius(22)
                        }
                        .buttonStyle(.plain)

                        if detail.episodes.count > 1 {
                            Button(action: { showEpisodeSheet = true }) {
                                HStack {
                                    Image(systemName: "list.bullet")
                                    Text("选集(\(detail.episodes.count))")
                                }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 20).padding(.vertical, 10)
                                .background(Color.accentColor.opacity(0.1)).cornerRadius(22)
                            }
                            .buttonStyle(.plain)
                        }
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
                VideoPlayerViewV2(video: playerVideo)
            }
        }
        .sheet(isPresented: $showEpisodeSheet) {
            FuliEpisodeSheetView(episodes: detail?.episodes ?? []) { ep in
                playEpisode(ep)
                showEpisodeSheet = false
            }
        }
    }

    private func loadDetail() {
        isLoading = true; errorMsg = nil; detail = nil
        Task {
            let result = await svc.fetchDetail(vodId: video.vodId)
            await MainActor.run {
                detail = result; isLoading = false
                if result.episodes.isEmpty {
                    errorMsg = "未解析到播放地址"
                }
            }
        }
    }

    private func playFirst() {
        guard let first = detail?.episodes.first else { return }
        playEpisode(first)
    }

    private func playEpisode(_ episode: FuliEpisode) {
        playerVideo = VodItem(
            vodId: video.vodId,
            vodName: "\(video.vodName) \(episode.name)",
            vodPic: video.vodPic,
            vodRemarks: "[福利]\(svc.platformName)",
            vodPlayUrl: episode.url
        )
        showPlayer = true
    }
}

// MARK: - 选集弹窗
struct FuliEpisodeSheetView: View {
    let episodes: [FuliEpisode]
    let onSelect: (FuliEpisode) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(episodes) { ep in
                        Button(action: { onSelect(ep); dismiss() }) {
                            Text(ep.name)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color(uiColor: .secondarySystemGroupedBackground))
                                .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
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
