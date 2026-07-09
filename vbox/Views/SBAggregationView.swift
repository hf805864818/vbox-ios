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
    @State private var player: AVPlayer?
    @State private var loadError: String?
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 0) {
            // 固定播放器
            ZStack {
                if let player = player {
                    VideoPlayer(player: player)
                        .aspectRatio(16/9, contentMode: .fit)
                } else {
                    Rectangle()
                        .fill(Color.black)
                        .aspectRatio(16/9, contentMode: .fit)
                        .overlay {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "play.slash")
                                        .font(.system(size: 40))
                                        .foregroundColor(.white.opacity(0.5))
                                    Text("暂无播放源")
                                        .font(.system(size: 13))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
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
            player?.pause()
            player = nil
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
        print("[SBAggregation] 播放: \(url)")
        guard let playURL = URL(string: url) else {
            print("[SBAggregation] ❌ URL 无效: \(url)")
            return
        }
        player?.pause()
        let p = AVPlayer(url: playURL)
        player = p
        p.play()
        isPlaying = true
    }
}