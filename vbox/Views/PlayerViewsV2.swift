import SwiftUI
import AVKit
import AVFoundation

// MARK: - 新版本播放器 (爱奇艺风格) - 最小可编译版本
struct VideoPlayerViewV2: View {
    let video: VodItem
    @State private var player: AVPlayer?
    @State private var isPlaying = true
    @State private var showControls = true
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isLocked = false
    @State private var showDanmaku = true
    @State private var showSettings = false
    @State private var showEpisodePicker = false
    @State private var showQualityPicker = false
    @State private var showDanmakuSettings = false
    @State private var selectedQuality = 1
    @State private var playbackSpeed: Double = 1.0
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
            PlayerSettingsViewV2(speed: $playbackSpeed, onSpeedChange: changePlaybackSpeed)
        }
        .sheet(isPresented: $showEpisodePicker) {
            EpisodePickerViewV2(video: video)
        }
        .sheet(isPresented: $showQualityPicker) {
            QualityPickerViewV2(selectedQuality: $selectedQuality, onQualityChange: changeQuality)
        }
        .sheet(isPresented: $showDanmakuSettings) {
            DanmakuSettingsViewV2(
                showDanmaku: $showDanmaku,
                opacity: $danmakuOpacity,
                fontSize: $danmakuFontSize
            )
        }
    }

    private func changePlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        player?.rate = Float(speed)
    }

    private func changeQuality(_ quality: Int) {
        selectedQuality = quality
    }

    private func setupPlayer() {
        // 简单的播放器初始化
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

// MARK: - 其他组件占位符
struct DanmakuOverlayViewV2: View {
    @Binding var showDanmaku: Bool
    let opacity: Double
    let fontSize: CGFloat

    var body: some View {
        EmptyView()
    }
}

struct PlayerSettingsViewV2: View {
    @Binding var speed: Double
    let onSpeedChange: (Double) -> Void
    let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0]

    @Environment(\.dismiss) private var dismiss

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("播放速度") {
                    ForEach(speeds, id: \.self) { s in
                        Button(action: {
                            speed = s
                            onSpeedChange(s)
                            dismiss()
                        }) {
                            HStack {
                                Text("\(s, specifier: "%.2f")x")
                                Spacer()
                                if s == speed {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Color(hex: "E11D48"))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("播放设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct EpisodePickerViewV2: View {
    let video: VodItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(1..<101, id: \.self) { ep in
                        Button(action: { dismiss() }) {
                            Text("\(ep)")
                                .font(.system(size: 14))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.1)))
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct QualityPickerViewV2: View {
    @Binding var selectedQuality: Int
    let onQualityChange: (Int) -> Void
    let qualities = ["标清", "高清", "蓝光"]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section("清晰度选择") {
                    ForEach(0..<qualities.count, id: \.self) { index in
                        Button(action: {
                            selectedQuality = index
                            onQualityChange(index)
                            dismiss()
                        }) {
                            HStack {
                                Text(qualities[index])
                                Spacer()
                                if index == selectedQuality {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Color(hex: "E11D48"))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("清晰度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("透明度: \(Int(opacity * 100))%")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Slider(value: $opacity, in: 0...1, step: 0.1)
                            .accentColor(Color(hex: "E11D48"))
                    }
                    .padding(.vertical, 4)
                }

                Section("弹幕字体大小") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("字号: \(Int(fontSize))")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Slider(value: $fontSize, in: 12...24, step: 2)
                            .accentColor(Color(hex: "E11D48"))
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("弹幕设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
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
