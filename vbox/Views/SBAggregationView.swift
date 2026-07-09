import SwiftUI
import AVKit

// MARK: - 色播聚合主页面
// 对应 Python SB聚合 脚本

struct SBAggregationView: View {
    let platform: YBoxPlatform2
    @StateObject private var svc = SBAggregationService.shared
    @State private var videos: [SBAggregationVideo] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                List {
                    ForEach(videos) { video in
                        NavigationLink(destination: SBAggregationPlayerView(
                            address: video.address,
                            title: video.title,
                            svc: svc
                        )) {
                            DailyBattleVideoCard(
                                cover: video.cover,
                                title: video.title,
                                remarks: "第\(video.remarks)期",
                                imageMode: .plain
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle(platform.name)
            .navigationBarTitleDisplayMode(.inline)

            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(UIColor.systemBackground).opacity(0.8))
            }

            if let err = loadError, videos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("加载失败")
                        .font(.title2)
                    Text(err)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Button("重试") {
                        load()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if videos.isEmpty { load() }
        }
    }

    private func load() {
        isLoading = true
        loadError = nil
        Task {
            let list = await svc.fetchList()
            await MainActor.run {
                videos = list
                isLoading = false
                if list.isEmpty {
                    loadError = "暂时无法获取数据，请稍后重试"
                }
            }
        }
    }
}

// MARK: - 色播聚合播放器页面

struct SBAggregationPlayerView: View {
    let address: String
    let title: String
    @ObservedObject var svc: SBAggregationService
    @State private var playItems: [SBAggregationPlayItem] = []
    @State private var selectedIdx = 0
    @State private var isLoading = true
    @State private var player = AVPlayer()
    @State private var loadError: String?
    @State private var playerStatus: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // 固定播放器
            ZStack {
                SBAggregationVideoPlayer(player: player)
                    .aspectRatio(16/9, contentMode: .fit)

                if playerStatus == "loading" {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                }

                if playerStatus == "failed" {
                    VStack(spacing: 8) {
                        Image(systemName: "play.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.6))
                        Text("播放失败，请尝试其他线路")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
            .background(Color.black)

            // 标题
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 独立滑动的线路选择框
            if playItems.count > 0 {
                Text("播放线路")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(playItems.enumerated()), id: \.offset) { idx, item in
                            Button(action: {
                                selectedIdx = idx
                                play(url: item.address)
                            }) {
                                HStack {
                                    Text(item.title)
                                        .font(.system(size: 14))
                                        .foregroundColor(selectedIdx == idx ? .accentColor : .primary)
                                    Spacer()
                                    if selectedIdx == idx {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 11))
                                            .foregroundColor(.accentColor)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(
                                    selectedIdx == idx
                                        ? Color.accentColor.opacity(0.08)
                                        : Color.clear
                                )
                            }
                            .buttonStyle(.plain)

                            if idx < playItems.count - 1 {
                                Divider()
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            } else if !isLoading {
                Spacer()
                Text("暂无可用线路")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                Spacer()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if playItems.isEmpty {
                load()
            }
        }
        .onDisappear {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }

    private func load() {
        isLoading = true
        Task {
            let items = await svc.fetchDetail(address: address)
            await MainActor.run {
                playItems = items
                isLoading = false
                if !items.isEmpty {
                    play(url: items[0].address)
                } else {
                    loadError = "获取播放地址失败"
                }
            }
        }
    }

    private func play(url: String) {
        // 确保 URL 有效
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        // 处理可能的 URL 编码问题
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        guard let playURL = URL(string: encoded) ?? URL(string: trimmed) else {
            print("[SBAggregation] ❌ URL 无效: \(url)")
            playerStatus = "failed"
            return
        }

        print("[SBAggregation] ▶️ 播放: \(playURL.absoluteString)")
        playerStatus = "loading"

        let playerItem = AVPlayerItem(url: playURL)
        player.replaceCurrentItem(with: playerItem)

        // 观察播放状态
        Task {
            // 等待一小段时间让播放器开始加载
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                switch playerItem.status {
                case .readyToPlay:
                    player.play()
                    playerStatus = ""
                    print("[SBAggregation] ✅ 播放成功")
                case .failed:
                    print("[SBAggregation] ❌ 播放失败: \(playerItem.error?.localizedDescription ?? "未知错误")")
                    playerStatus = "failed"
                default:
                    // 仍在加载中，给更多时间
                    player.play()
                    playerStatus = ""
                }
            }
        }
    }
}

// MARK: - AVPlayer 包装（支持状态观察）

struct SBAggregationVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        vc.videoGravity = .resizeAspect
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player {
            vc.player = player
        }
    }
}