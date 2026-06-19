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
    let area: Double
    let currentTime: Double
    let items: [DanmakuRenderItem]

    var body: some View {
        GeometryReader { geo in
            let maxAreaHeight = geo.size.height * area
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
                    // 限制弹幕不超出显示区域
                    .offset(y: 0)
                    .clipped()
                    .frame(maxHeight: maxAreaHeight, alignment: .top)
            }
        }
        .clipped()
    }
}

struct EpisodePickerPanelV2: View {
    @ObservedObject var playerState: PlayerState
    @Binding var isPresented: Bool
    var isPortrait: Bool = true
    @EnvironmentObject private var settings: AppSettings

    /// 自适应皮肤的按钮背景色
    private var buttonBackground: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .tertiarySystemBackground)
        }
        return Color.white.opacity(0.12)
    }

    private var buttonBorder: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .separator)
        }
        return Color.white.opacity(0.15)
    }

    private var textNormal: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .label)
        }
        return Color.white.opacity(0.9)
    }

    private var textEmpty: Color {
        if settings.usesFrostedSkin {
            return Color(uiColor: .secondaryLabel)
        }
        return Color.white.opacity(0.5)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !playerState.episodeItems.isEmpty {
                // 河马剧场风格：浅蓝色按钮网格
                ScrollView(showsIndicators: true) {
                    if isPortrait {
                        // 竖屏：3列网格
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                            episodeGridItems()
                        }
                        .padding(14)
                    } else {
                        // 横屏：5列网格
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                            episodeGridItems()
                        }
                        .padding(10)
                    }
                }
            } else {
                Text("暂无集数信息")
                    .foregroundColor(textEmpty)
                    .padding(.vertical, 40)
            }
        }
    }

    @ViewBuilder
    private func episodeGridItems() -> some View {
        ForEach(playerState.episodeItems) { episode in
            Button(action: {
                playerState.switchToEpisode(index: episode.id)
                isPresented = false
            }) {
                HStack(spacing: isPortrait ? 6 : 4) {
                    Text(episodeDisplayName(episode.name, index: episode.id))
                        .font(.system(size: isPortrait ? 13 : 11, weight: episode.id == playerState.currentEpisodeIndex ? .semibold : .regular))
                        .foregroundColor(episode.id == playerState.currentEpisodeIndex ? Color(hex: "2196F3") : textNormal)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    if episode.id == playerState.currentEpisodeIndex {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: isPortrait ? 12 : 10))
                            .foregroundColor(Color(hex: "2196F3"))
                    }
                }
                .padding(.horizontal, isPortrait ? 12 : 8)
                .padding(.vertical, isPortrait ? 12 : 8)
                .background(
                    RoundedRectangle(cornerRadius: isPortrait ? 8 : 6)
                        .fill(episode.id == playerState.currentEpisodeIndex ? Color(hex: "2196F3").opacity(0.2) : buttonBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: isPortrait ? 8 : 6)
                        .stroke(buttonBorder, lineWidth: 0.5)
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private func episodeDisplayName(_ name: String, index: Int) -> String {
        let cleaned = (name as NSString).deletingPathExtension
        if cleaned.count > 8 {
            return "第\(index + 1)集"
        }
        return cleaned.isEmpty ? "第\(index + 1)集" : cleaned
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
