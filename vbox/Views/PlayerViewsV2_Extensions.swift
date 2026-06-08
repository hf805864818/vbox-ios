import SwiftUI
import AVKit
import AVFoundation
import MediaPlayer

struct GestureControlView: View {
    @ObservedObject var playerState: PlayerState
    @State private var startBrightness: Double = 0.5
    @State private var startVolume: Double = 0.5
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        if !isDragging { isDragging = true; startBrightness = playerState.brightness; startVolume = playerState.volume }
                        let half = geo.size.width / 2
                        let delta = -value.translation.height / geo.size.height * 0.8
                        if value.location.x < half {
                            playerState.brightness = max(0, min(1, startBrightness + delta))
                            UIScreen.main.brightness = playerState.brightness
                        } else {
                            playerState.volume = max(0, min(1, startVolume + delta))
                            let vv = MPVolumeView()
                            for v in vv.subviews { if let s = v as? UISlider { s.value = Float(playerState.volume) } }
                        }
                    }
                    .onEnded { _ in isDragging = false }
                )
        }
    }
}

struct DanmakuOverlayViewV2: View {
    @Binding var showDanmaku: Bool
    let opacity: Double
    let fontSize: CGFloat

    var body: some View {
        Text("Danmaku").foregroundColor(.white.opacity(opacity)).font(.system(size: fontSize))
    }
}

struct EpisodePickerPanelV2: View {
    @ObservedObject var playerState: PlayerState
    var body: some View {
        ScrollView {
            if !playerState.baiduFileList.isEmpty {
                // 百度网盘多文件列表
                let columns = Array(repeating: GridItem(.flexible()), count: 4)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(playerState.baiduFileList.enumerated()), id: \.offset) { idx, file in
                        Button(action: {
                            playerState.switchBaiduFile(index: idx)
                        }) {
                            Text(episodeName(file.name, index: idx))
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                                .frame(minWidth: 56, minHeight: 56)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(idx == playerState.currentEpisodeIndex ? Color.blue : Color.white.opacity(0.1))
                                )
                        }
                    }
                }
                .padding()
            } else {
                // 普通多集占位
                Text("暂无集数信息")
                    .foregroundColor(.gray)
                    .padding()
            }
        }
    }
    
    private func episodeName(_ name: String, index: Int) -> String {
        // 去掉扩展名，取短名
        let cleaned = (name as NSString).deletingPathExtension
        if cleaned.count > 8 {
            return "\(index + 1)"
        }
        return cleaned
    }
}

struct AirPlayViewV2: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct DanmakuRenderItem: Identifiable {
    let id: Int
    let content: String
    var x: CGFloat
    let y: CGFloat
    let color: Int
}
