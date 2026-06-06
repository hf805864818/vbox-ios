import SwiftUI
import AVKit
import AVFoundation

// MARK: - 新版本播放器 (爱奇艺风格)
struct VideoPlayerViewV2: View {
    let video: VodItem
    @State private var player: AVPlayer?
    @State private var isPlaying = true
    @State private var showControls = true
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var showSettings = false
    @State private var showEpisodePicker = false
    @State private var showQualityPicker = false
    @State private var showDanmakuSettings = false
    @State private var selectedQuality = 1
    @State private var playbackSpeed: Double = 1.0
    @State private var showDanmaku = true
    @State private var danmakuOpacity: Double = 0.8
    @State private var danmakuFontSize: CGFloat = 16

    @Environment(\.dismiss) private var dismiss

    private let qualities = ["标清", "高清", "蓝光"]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .scaleEffect(1.5)
            } else if let error = loadError {
                Text(error)
                    .foregroundColor(.white)
            } else if let player = player {
                ZStack {
                    AVPlayerControllerRepresentableV2(player: player)
                        .ignoresSafeArea()
                    
                    if showDanmaku {
                        DanmakuOverlayViewV2(
                            showDanmaku: $showDanmaku,
                            opacity: danmakuOpacity,
                            fontSize: danmakuFontSize
                        )
                        .allowsHitTesting(false)
                    }

                    if showControls {
                        playerControlsView
                    }
                }
                .onTapGesture {
                    showControls.toggle()
                }
            }
        }
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            player?.pause()
        }
        .sheet(isPresented: $showSettings) {
            PlayerSettingsViewV2(speed: $playbackSpeed, onSpeedChange: { _ in })
        }
        .sheet(isPresented: $showEpisodePicker) {
            EpisodePickerViewV2(video: video)
        }
        .sheet(isPresented: $showQualityPicker) {
            QualityPickerViewV2(selectedQuality: $selectedQuality, onQualityChange: { _ in })
        }
        .sheet(isPresented: $showDanmakuSettings) {
            DanmakuSettingsViewV2(
                showDanmaku: $showDanmaku,
                opacity: $danmakuOpacity,
                fontSize: $danmakuFontSize
            )
        }
    }

    private var playerControlsView: some View {
        VStack {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .foregroundColor(.white)
                }
                Spacer()
            }
            .padding()

            Spacer()

            HStack {
                Button(action: { isPlaying.toggle() }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .foregroundColor(.white)
                }

                Button(action: { showQualityPicker = true }) {
                    Text(qualities[selectedQuality])
                        .foregroundColor(.white)
                }

                Button(action: { showEpisodePicker = true }) {
                    Image(systemName: "list.bullet")
                        .foregroundColor(.white)
                }
                
                AirPlayViewV2()
                    .frame(width: 30, height: 30)
                
                Button(action: { showDanmakuSettings = true }) {
                    Image(systemName: "text.bubble")
                        .foregroundColor(.white)
                }

                Spacer()
            }
            .padding()
        }
    }

    private func setupPlayer() {
        guard let url = URL(string: video.vodPlayUrl ?? "") else {
            loadError = "无效的URL"
            isLoading = false
            return
        }
        player = AVPlayer(url: url)
        player?.play()
        isPlaying = true
        isLoading = false
    }
}

// MARK: - AVPlayer 控制器封装 V2
struct AVPlayerControllerRepresentableV2: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}
}

struct DanmakuSettingsViewV2: View {
    @Binding var showDanmaku: Bool
    @Binding var opacity: Double
    @Binding var fontSize: CGFloat

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("弹幕开关") {
                    Toggle("开启弹幕", isOn: $showDanmaku)
                }

                Section("弹幕透明度") {
                    Slider(value: $opacity, in: 0...1, step: 0.1)
                }

                Section("弹幕字体大小") {
                    Slider(value: $fontSize, in: 12...24, step: 2)
                }
            }
            .navigationTitle("弹幕设置")
        }
    }
}

// MARK: - 弹幕数据模型
private struct DanmakuItemData: Identifiable {
    let text: String
    var x: CGFloat
    let y: CGFloat
    let id: Int
}

// MARK: - 弹幕覆盖层
struct DanmakuOverlayViewV2: View {
    @Binding var showDanmaku: Bool
    let opacity: Double
    let fontSize: CGFloat

    @State private var danmakuItems: [DanmakuItemData] = []
    @State private var allDanmaku: [(time: Double, text: String)] = []
    @State private var currentIndex = 0

    var body: some View {
        GeometryReader { geo in
            ForEach(danmakuItems) { item in
                Text(item.text)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(.white.opacity(opacity))
                    .shadow(color: .black, radius: 2)
                    .position(x: item.x, y: item.y)
            }
        }
    }
}

struct AirPlayViewV2: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView()
    }
    
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - 其他组件
struct PlayerSettingsViewV2: View {
    @Binding var speed: Double
    var onSpeedChange: (Double) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("播放速度") {
                    ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { s in
                        Button("\(s)x") {
                            speed = s
                            onSpeedChange(s)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("播放设置")
        }
    }
}

struct EpisodePickerViewV2: View {
    let video: VodItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(1..<21, id: \.self) { ep in
                    Button("第\(ep)集") {
                        dismiss()
                    }
                }
            }
            .navigationTitle("选集")
        }
    }
}

struct QualityPickerViewV2: View {
    @Binding var selectedQuality: Int
    var onQualityChange: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(0..<3, id: \.self) { index in
                    Button(["标清", "高清", "蓝光"][index]) {
                        selectedQuality = index
                        onQualityChange(index)
                        dismiss()
                    }
                }
            }
            .navigationTitle("清晰度")
        }
    }
}
