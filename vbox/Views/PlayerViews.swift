import SwiftUI
import AVKit
import AVFoundation

// MARK: - 视频详情视图
struct VideoDetailView: View {
    let video: VodItem
    @State private var showPlayer = false
    @State private var showPanPicker = false
    @State private var selectedPanURL: String?
    @State private var isFavorite = false
    @State private var panLinks: [(url: String, name: String)] = []
    @State private var isLoadingPan = false
    @Environment(\.dismiss) private var dismiss

    private func loadPanLinks() {
        isLoadingPan = true
        Task {
            if let result = await SpiderManager.shared.resolveCloudPlay(from: video.vodId) {
                await MainActor.run {
                    panLinks = result.links
                    isLoadingPan = false
                }
            } else {
                await MainActor.run { isLoadingPan = false }
            }
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
                        AsyncImage(url: URL(string: video.vodPic)) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            default:
                                Rectangle().fill(Color.gray.opacity(0.3))
                            }
                        }
                        .frame(height: 220).clipped()

                        LinearGradient(colors: [.clear, .black.opacity(0.6), .black.opacity(0.95)],
                                       startPoint: .top, endPoint: .bottom)

                        Button(action: {
                            if video.vodRemarks?.hasPrefix("☁️") == true {
                                if panLinks.isEmpty {
                                    loadPanLinks()
                                } else {
                                    showPanPicker = true
                                }
                            } else {
                                showPlayer = true
                            }
                        }) {
                            ZStack {
                                Circle().fill(Color(hex: "E11D48")).frame(width: 70, height: 70)
                                Image(systemName: "play.fill").font(.system(size: 28, weight: .bold)).foregroundColor(.white).offset(x: 3)
                            }
                        }.padding(16)
                    }

                    // 信息区
                    VStack(alignment: .leading, spacing: 16) {
                        Text(video.vodName).font(.system(size: 22, weight: .bold))
                        HStack(spacing: 12) {
                            TagLabel(text: video.vodRemarks ?? "")
                            TagLabel(text: video.vodYear ?? "")
                            TagLabel(text: "高清")
                        }

                        HStack(spacing: 16) {
                            ActionButton(icon: "play.fill", title: "播放") { showPlayer = true }
                            ActionButton(icon: "list.bullet", title: "选集") {}
                            ActionButton(icon: "square.and.arrow.down", title: "下载") {}
                            ActionButton(icon: "square.and.arrow.up", title: "分享") {}
                        }

                        // HStack(spacing: 8) {
                        //     Button(action: { useNewPlayer.toggle() }) {
                        //         Text(useNewPlayer ? "新播放器 ✓" : "旧播放器")
                        //             .font(.system(size: 12, weight: .medium))
                        //             .foregroundColor(useNewPlayer ? Color(hex: "E11D48") : .secondary)
                        //             .padding(.horizontal, 12)
                        //             .padding(.vertical, 6)
                        //             .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.1)))
                        //     }
                        // }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("剧情简介").font(.system(size: 16, weight: .semibold))
                            Text(video.vodContent ?? "暂无简介").font(.system(size: 14)).foregroundColor(.secondary).lineSpacing(4)
                        }

                        // 网盘资源展示
                        if video.vodRemarks?.hasPrefix("☁️") == true {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: "cloud.fill").font(.system(size: 14)).foregroundColor(.blue)
                                    if isLoadingPan {
                                        Text("正在加载网盘资源...").font(.system(size: 14)).foregroundColor(.secondary)
                                        Spacer()
                                        ProgressView().scaleEffect(0.8)
                                    } else if panLinks.isEmpty {
                                        Text("未找到网盘链接").font(.system(size: 14)).foregroundColor(.secondary)
                                    } else {
                                        Text("网盘资源 (\(panLinks.count) 个)").font(.system(size: 14, weight: .semibold)).foregroundColor(.blue)
                                    }
                                    Spacer()
                                }
                                if !isLoadingPan, !panLinks.isEmpty {
                                    ForEach(Array(panLinks.enumerated()), id: \.offset) { idx, link in
                                        Button(action: { showPanPicker = true }) {
                                            HStack(spacing: 10) {
                                                Image(systemName: "link.circle.fill").font(.system(size: 16)).foregroundColor(driveColor(link.name))
                                                Text(link.name).font(.system(size: 13)).foregroundColor(.primary)
                                                Spacer()
                                                Text("点击选择").font(.system(size: 11)).foregroundColor(Color(hex: "E11D48"))
                                            }
                                            .padding(10)
                                            .background(Color.white.opacity(0.05))
                                            .cornerRadius(8)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("剧集列表").font(.system(size: 16, weight: .semibold))
                                Spacer()
                                Text("共 24 集").font(.system(size: 12)).foregroundColor(.secondary)
                            }
                            EpisodeGridView()
                        }
                        .padding(.top, 8)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("弹幕").font(.system(size: 16, weight: .semibold))
                                Spacer()
                                Text("已有 1024 条弹幕").font(.system(size: 12)).foregroundColor(.secondary)
                            }
                            DanmakuInputView()
                            DanmakuListView()
                        }
                    }
                    .padding(20).padding(.bottom, 100)
                }
            }
            .background(Color(hex: "000000"))
            .ignoresSafeArea()
            .fullScreenCover(isPresented: $showPlayer) {
                // VideoPlayerViewV2(video: video) // 暂时禁用新播放器
                VideoPlayerView(video: video) // 使用旧播放器
            }
            .sheet(isPresented: $showPanPicker) {
                PanLinkPickerView(video: video, preloadedLinks: panLinks.isEmpty ? nil : panLinks)
            }
            .onAppear {
                if video.vodRemarks?.hasPrefix("☁️") == true, panLinks.isEmpty {
                    loadPanLinks()
                }
            }
            .onDisappear { }

            // 返回
            VStack {
                Button(action: { dismiss() }) {
                    ZStack {
                        Circle().fill(.ultraThinMaterial).frame(width: 44, height: 44)
                        Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                    }
                }
                .padding(.leading, 16).padding(.top, 12)
                Spacer()
            }
            .zIndex(1000)
        }
    }
}

// MARK: - 辅助组件
struct TagLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundColor(.primary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(LinearGradient(colors: [.white.opacity(0.1), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
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
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            ForEach(1..<25) { ep in
                Button(action: { selectedEpisode = ep }) {
                    Text("\(ep)").font(.system(size: 14, weight: ep == selectedEpisode ? .semibold : .medium))
                        .foregroundColor(ep == selectedEpisode ? .white : .primary).frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(ep == selectedEpisode ? Color(hex: "E11D48") : Color.primary.opacity(0.1)))
                }.buttonStyle(PlainButtonStyle())
            }
        }
    }
}

// MARK: - 弹幕组件
struct DanmakuItem: Identifiable {
    let id = UUID()
    let text: String
    let time: Date
}

struct DanmakuInputView: View {
    @State private var text = ""
    @State private var danmakuList: [DanmakuItem] = []
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TextField("输入弹幕内容...", text: $text)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .font(.system(size: 14))
                Button(action: {
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    danmakuList.append(DanmakuItem(text: text, time: Date()))
                    text = ""
                }) {
                    Text("发送").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color(hex: "E11D48")).cornerRadius(8)
                }
            }
        }
    }
}

struct DanmakuListView: View {
    @State private var danmakuList: [DanmakuItem] = []
    var body: some View {
        if danmakuList.isEmpty {
            Text("暂无弹幕").font(.system(size: 13)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 20)
        } else {
            ForEach(danmakuList) { item in
                HStack {
                    Text(item.text).font(.system(size: 13)).foregroundColor(.primary)
                    Spacer()
                    Text(item.time, style: .time).font(.system(size: 11)).foregroundColor(.secondary)
                }.padding(.vertical, 4)
            }
        }
    }
}
