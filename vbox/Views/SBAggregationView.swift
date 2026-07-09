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

    var body: some View {
        ZStack {
            List {
                // 播放器
                if let player = player {
                    VideoPlayer(player: player)
                        .aspectRatio(16/9, contentMode: .fit)
                        .cornerRadius(12)
                        .listRowInsets(EdgeInsets())
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .aspectRatio(16/9, contentMode: .fit)
                        .cornerRadius(12)
                        .overlay {
                            if isLoading {
                                ProgressView()
                            } else {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 60))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        }
                        .listRowInsets(EdgeInsets())
                }

                // 标题
                Section {
                    Text(title)
                        .font(.headline)
                }

                // 线路选择
                if playItems.count > 1 {
                    Section("播放线路") {
                        ForEach(Array(playItems.enumerated()), id: \.offset) { idx, item in
                            Button(action: {
                                selectedIdx = idx
                                play(url: item.address)
                            }) {
                                HStack {
                                    Text(item.title)
                                        .foregroundColor(selectedIdx == idx ? .accentColor : .primary)
                                    if selectedIdx == idx {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.grouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)

            if isLoading {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(UIColor.systemBackground).opacity(0.8))
            }
        }
        .onAppear {
            if playItems.isEmpty {
                load()
            }
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
        guard let playURL = URL(string: url) else { return }
        let p = AVPlayer(url: playURL)
        player = p
        p.play()
    }
}