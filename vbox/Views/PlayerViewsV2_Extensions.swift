import SwiftUI
import AVKit
import AVFoundation
import MediaPlayer

struct GestureControlView: View {
    @ObservedObject var playerState: PlayerState
    @State private var startBrightness: Double = 0.5
    @State private var startVolume: Double = 0.5
    @State private var gestureMode: GestureMode?
    @State private var isDragging = false
    let onTap: () -> Void

    private enum GestureMode {
        case brightness
        case volume
        case ignored
    }

    var body: some View {
        GeometryReader { geo in
            Color.clear.contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                .gesture(DragGesture(minimumDistance: 14)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            startBrightness = playerState.brightness
                            startVolume = playerState.volume
                            let vertical = abs(value.translation.height)
                            let horizontal = abs(value.translation.width)
                            if vertical < 18 || horizontal > vertical * 0.75 {
                                gestureMode = .ignored
                            } else {
                                gestureMode = value.startLocation.x < geo.size.width / 2 ? .brightness : .volume
                            }
                        }
                        guard gestureMode != .ignored else { return }
                        let half = geo.size.width / 2
                        let sensitivity = max(0.45, min(0.9, geo.size.height / 700))
                        let delta = -value.translation.height / geo.size.height * sensitivity
                        if gestureMode == .brightness || (gestureMode == nil && value.location.x < half) {
                            playerState.brightness = max(0, min(1, startBrightness + delta))
                            UIScreen.main.brightness = playerState.brightness
                        } else {
                            playerState.volume = max(0, min(1, startVolume + delta))
                            SystemVolumeController.shared.setVolume(Float(playerState.volume))
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        gestureMode = nil
                    }
                )
        }
    }
}

struct DanmakuOverlayViewV2: View {
    @Binding var showDanmaku: Bool
    let opacity: Double
    let fontSize: CGFloat
    let currentTime: Double
    let items: [DanmakuRenderItem]

    var body: some View {
        GeometryReader { geo in
            ForEach(items) { item in
                let progress = min(max((currentTime - item.time) / item.duration, 0), 1)
                let textWidth = max(80, CGFloat(item.content.count) * fontSize * 0.72)
                Text(item.content)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundColor(Color(hexRGB: item.color).opacity(opacity))
                    .shadow(color: .black.opacity(0.85), radius: 1, x: 1, y: 1)
                    .position(
                        x: geo.size.width + textWidth / 2 - progress * (geo.size.width + textWidth),
                        y: CGFloat(item.lane) * (fontSize + 10) + 28
                    )
            }
        }
        .clipped()
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
    let time: Double
    let lane: Int
    let color: Int
    let duration: Double
}

final class SystemVolumeController {
    static let shared = SystemVolumeController()
    private let volumeView = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
    private weak var slider: UISlider?

    private init() {
        volumeView.isHidden = true
        DispatchQueue.main.async {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }?
                .addSubview(self.volumeView)
            self.slider = self.volumeView.subviews.compactMap { $0 as? UISlider }.first
        }
    }

    func setVolume(_ value: Float) {
        DispatchQueue.main.async {
            self.slider?.setValue(max(0, min(1, value)), animated: false)
            self.slider?.sendActions(for: .touchUpInside)
        }
    }
}

extension Color {
    init(hexRGB: Int) {
        let red = Double((hexRGB >> 16) & 0xff) / 255.0
        let green = Double((hexRGB >> 8) & 0xff) / 255.0
        let blue = Double(hexRGB & 0xff) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
