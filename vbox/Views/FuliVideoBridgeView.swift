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
    @State private var showEpisodePanel = false

    // 播放地址解析相关
    @State private var isResolvingURL = false
    @State private var resolveError: String? = nil
    @State private var pendingEpisode: FuliEpisode? = nil

    var body: some View {
        ZStack {
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
                                    Text(detail.episodes.count == 1 ? "立即播放" : "播放\(selectedEpisode?.name ?? detail.episodes.first!.name)")
                                }
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 28).padding(.vertical, 10)
                                .background(Color.accentColor).cornerRadius(22)
                            }
                            .buttonStyle(.plain)

                            if detail.episodes.count > 1 {
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showEpisodePanel.toggle()
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "line.3.horizontal.decrease")
                                        Text("线路(\(detail.episodes.count))")
                                    }
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(showEpisodePanel ? Color(hex: "2196F3") : .accentColor)
                                    .padding(.horizontal, 20).padding(.vertical, 10)
                                    .background(showEpisodePanel ? Color(hex: "2196F3").opacity(0.15) : Color.accentColor.opacity(0.1))
                                    .cornerRadius(22)
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

            // 线路悬浮弹窗（类似播放器倍速面板）
            if showEpisodePanel, let detail = detail, detail.episodes.count > 1 {
                // 半透明背景，点击关闭
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showEpisodePanel = false
                        }
                    }

                // 悬浮面板
                FuliEpisodeFloatingPanel(
                    episodes: detail.episodes,
                    selectedEpisode: selectedEpisode ?? detail.episodes.first,
                    onSelect: { ep in
                        selectedEpisode = ep
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showEpisodePanel = false
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
        }
    }

    private func loadDetail() {
        isLoading = true; errorMsg = nil; detail = nil
        Task {
            await svc.ensureHostReady()
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
            await MainActor.run {
                isResolvingURL = false
                if result.url.isEmpty {
                    resolveError = "无法获取有效的播放地址"
                } else {
                    playerVideo = VodItem(
                        vodId: video.vodId,
                        vodName: "\(video.vodName) \(episode.name)",
                        vodPic: video.vodPic,
                        vodRemarks: "[福利]\(svc.platformName)",
                        vodPlayUrl: result.url,
                        customHeaders: result.headers
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
}

// MARK: - 线路悬浮面板
//
// 仿照播放器倍速面板（PlayerSettingsPanelV2）设计的悬浮线路选择器。
// 显示为半透明背景上的垂直列表面板，点击外部区域自动关闭。
struct FuliEpisodeFloatingPanel: View {
    let episodes: [FuliEpisode]
    let selectedEpisode: FuliEpisode?
    let onSelect: (FuliEpisode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack {
                Text("选择线路")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // 线路列表
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
