import SwiftUI
import AVKit
import AVFoundation
import MediaPlayer
import MediaPlayer

// MARK: - 手势控制视图（嵌入 PlayerContainerView）
struct GestureControlView: View {
    @ObservedObject var playerState: PlayerState
    
    @State private var startBrightness: Double = 0.5
    @State private var startVolume: Double = 0.5
    @State private var isDragging = false
    @State private var showIndicator = false
    @State private var indicatorType = ""
    @State private var indicatorValue: Double = 0
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 手势区域
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                    startBrightness = playerState.brightness
                                    startVolume = playerState.volume
                                }
                                let half = geo.size.width / 2
                                let delta = -value.translation.height / geo.size.height * 0.8
                                
                                if value.location.x < half {
                                    // 左侧：亮度
                                    let newVal = max(0, min(1, startBrightness + delta))
                                    playerState.brightness = newVal
                                    UIScreen.main.brightness = newVal
                                    showIndicator = true
                                    indicatorType = "🌞"
                                    indicatorValue = newVal
                                } else {
                                    // 右侧：音量
                                    let newVal = max(0, min(1, startVolume + delta))
                                    playerState.volume = newVal
                                    updateVolume(newVal)
                                    showIndicator = true
                                    indicatorType = "🔊"
                                    indicatorValue = newVal
                                }
                            }
                            .onEnded { _ in
                                isDragging = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        showIndicator = false
                                    }
                                }
                                // 轻触不显示控制栏，拖动才显示
                                if abs(startBrightness - playerState.brightness) > 0.01 || abs(startVolume - playerState.volume) > 0.01 {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        playerState.showControls = true
                                    }
                                }
                            }
                    )
                    .onTapGesture(count: 2) {
                        // 双击切换播放/暂停
                        if let p = playerState.player {
                            playerState.isPlaying ? p.pause() : p.play()
                            playerState.isPlaying.toggle()
                        }
                    }
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            playerState.showControls.toggle()
                        }
                    }
                
                // 亮度/音量指示器
                if showIndicator {
                    VStack(spacing: 8) {
                        Text(indicatorType)
                            .font(.system(size: 32))
                        Text("\(Int(indicatorValue * 100))%")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 80, height: 80)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(12)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .transition(.opacity)
                }
            }
        }
    }
    
    private func updateVolume(_ volume: Double) {
        let volumeView = MPVolumeView()
        for view in volumeView.subviews {
            if let slider = view as? UISlider {
                slider.value = Float(volume)
                break
            }
        }
    }
}

// MARK: - LogVar弹幕覆盖层（数据驱动）
struct DanmakuOverlayViewV2: View {
    let items: [DanmakuRenderItem]
    let opacity: Double
    let fontSize: CGFloat

    var body: some View {
        GeometryReader { geo in
            ForEach(items) { item in
                Text(item.content)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(item.color == 16777215 ? .white : danmakuColor(item.color).opacity(opacity))
                    .shadow(color: .black, radius: 2)
                    .position(x: item.x, y: item.y)
                    .lineLimit(1)
            }
        }
    }
    
    private func danmakuColor(_ decimal: Int) -> Color {
        let r = Double((decimal >> 16) & 0xFF) / 255.0
        let g = Double((decimal >> 8) & 0xFF) / 255.0
        let b = Double(decimal & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - 选集面板（对接现有剧集数据）
struct EpisodePickerPanelV2: View {
    let video: VodItem
    @ObservedObject var playerState: PlayerState
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(playerState.episodeList.isEmpty ? "暂无剧集信息" : "共 \(playerState.episodeList.count) 集")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                
                if !playerState.episodeList.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                        ForEach(playerState.episodeList, id: \.index) { ep in
                            Button(action: { switchToEpisode(ep) }) {
                                Text(ep.title.isEmpty ? "\(ep.index)" : ep.title)
                                    .font(.system(size: 13, weight: playerState.currentEpisodeIndex == ep.index ? .semibold : .regular))
                                    .foregroundColor(playerState.currentEpisodeIndex == ep.index ? .white : .white.opacity(0.8))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(playerState.currentEpisodeIndex == ep.index ? Color(hex: "00BEFF") : Color.white.opacity(0.1))
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }
    
    private func switchToEpisode(_ ep: (index: Int, title: String, url: String)) {
        guard !ep.url.isEmpty else { return }
        playerState.currentEpisodeIndex = ep.index
        // 保存进度
        saveProgress(video.vodId, ep.index)
        // 切换播放
        if let url = URL(string: ep.url) {
            playerState.cleanup()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                playerState.isLoading = true
                playerState.loadError = nil
                let asset = AVURLAsset(url: url)
                let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                playerState.player = p
                playerState.isLoading = false
                p.play()
            }
        }
        dismiss()
    }
    
    private func saveProgress(_ videoId: String, _ episode: Int) {
        var dict = UserDefaults.standard.dictionary(forKey: "play_history") ?? [:]
        dict[videoId] = ["episode": episode, "time": Date().timeIntervalSince1970]
        UserDefaults.standard.set(dict, forKey: "play_history")
    }
}

// MARK: - AirPlay 视图
struct AirPlayViewV2: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView()
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - 弹幕渲染数据模型
struct DanmakuRenderItem: Identifiable {
    let id: Int
    let content: String
    var x: CGFloat
    let y: CGFloat
    let color: Int
}
