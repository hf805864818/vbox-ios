import SwiftUI
import AVKit
import AVFoundation

// MARK: - 旧播放器已移除，统一使用 VideoPlayerViewV2
// 旧播放器: VideoPlayerView, DanmakuOverlayView, EpisodePickerView,
// PlayerSettingsView, AirPlayView, AVPlayerControllerRepresentable,
// SupportedOrientationsModifier, PanPlayerView, AVPlayerController2
// 已全部移除，网盘和切片资源统一走新版 VideoPlayerViewV2

struct SupportedOrientationsModifier: ViewModifier {
    let supportedOrientations: UIInterfaceOrientationMask
    func body(content: Content) -> some View {
        content
            .onAppear { UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation"); UINavigationController.attemptRotationToDeviceOrientation() }
            .onDisappear { UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation"); UINavigationController.attemptRotationToDeviceOrientation() }
    }
}

extension View {
    func supportedOrientations(_ orientations: UIInterfaceOrientationMask) -> some View {
        self.modifier(SupportedOrientationsModifier(supportedOrientations: orientations))
    }
}

// MARK: - 工具
func formatTime2(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "00:00" }
    let total = Int(t); let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

// MARK: - 网盘链接选择视图（走新版播放器）
struct PanLinkPickerView: View {
    let video: VodItem
    var preloadedLinks: [(url: String, name: String)]? = nil
    @State private var links: [(url: String, name: String)] = []
    @State private var isLoading = true
    @State private var showPlayer = false
    @State private var selectedPanVideo: VodItem?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationView {
            ZStack { Color(hex: "0F0F23").ignoresSafeArea()
                if isLoading { VStack(spacing: 16) { ProgressView().scaleEffect(1.5).tint(.white); Text("正在解析网盘链接...").foregroundColor(.secondary) } }
                else if links.isEmpty { VStack(spacing: 16) { Image(systemName: "cloud.slash").font(.system(size: 40)).foregroundColor(.gray); Text("未找到可用的网盘链接").foregroundColor(.secondary) } }
                else { ScrollView { VStack(spacing: 12) {
                    HStack { Image(systemName: "cloud.fill").foregroundColor(.blue); Text(video.vodName).font(.system(size: 18, weight: .bold)); Spacer() }.padding(.horizontal, 20).padding(.top, 16)
                    Text("选择网盘资源播放").font(.system(size: 14)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20)
                    ForEach(Array(links.enumerated()), id: \.offset) { idx, link in
                        Button(action: {
                            selectedPanVideo = VodItem(vodId: link.url, vodName: "\(video.vodName) - \(link.name)",
                                                      vodPic: video.vodPic, vodRemarks: "☁️网盘", vodPlayUrl: link.url)
                            showPlayer = true
                        }) {
                            HStack(spacing: 14) {
                                ZStack { RoundedRectangle(cornerRadius: 12).fill(driveColor(for: link.name).opacity(0.15)).frame(width: 48, height: 48)
                                    Image(systemName: driveIcon(for: link.name)).font(.system(size: 22)).foregroundColor(driveColor(for: link.name)) }
                                VStack(alignment: .leading, spacing: 4) { Text(link.name).font(.system(size: 15, weight: .semibold)); Text(link.url).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1) }
                                Spacer()
                                Image(systemName: "play.circle.fill").font(.system(size: 28)).foregroundColor(Color(hex: "E11D48"))
                            }.padding(14).background(Color.white.opacity(0.05)).cornerRadius(14)
                        }.buttonStyle(.plain).padding(.horizontal, 16)
                    }
                }.padding(.bottom, 40) } }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { dismiss() } } }
        }
        .fullScreenCover(isPresented: $showPlayer) {
            if let panVideo = selectedPanVideo {
                VideoPlayerViewV2(video: panVideo)
            }
        }
        .onAppear {
            if let pre = preloadedLinks, !pre.isEmpty { links = pre; isLoading = false; return }
            guard let playUrl = video.vodPlayUrl, let data = playUrl.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { isLoading = false; return }
            links = json.compactMap { item in guard let url = item["url"], let name = item["name"] else { return nil }; return (url, name) }
            isLoading = false
        }
    }
    private func driveColor(for name: String) -> Color { if name.contains("115") { return .orange }; if name.contains("阿里") { return .blue }; if name.contains("夸克") { return .purple }; if name.contains("百度") { return .green }; return .gray }
    private func driveIcon(for name: String) -> String { if name.contains("115") { return "1.circle.fill" }; if name.contains("阿里") { return "a.circle.fill" }; if name.contains("夸克") { return "q.circle.fill" }; if name.contains("百度") { return "b.circle.fill" }; return "cloud.fill" }
}
