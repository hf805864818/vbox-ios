import SwiftUI
import AVKit
import AVFoundation
import MediaPlayer

struct GestureControlView: View {
    @ObservedObject var playerState: PlayerState
    @State private var startBrightness: Double = 0.5
    @State private var startVolume: Double = 0.5
    @State private var startSeekTime: Double = 0
    @State private var gestureMode: GestureMode?
    @State private var isDragging = false
    let onTap: () -> Void

    private enum GestureMode {
        case brightness
        case volume
        case seek
        case ignored
    }

    /// 任意弹窗显示时禁用长按
    private var isAnyPopupPresented: Bool {
        playerState.showSettings ||
        playerState.showEpisodePicker ||
        playerState.showQualityPicker ||
        playerState.showDanmakuSettings ||
        playerState.showEnginePicker ||
        playerState.showDanmakuInput ||
        playerState.showToolsMenu ||
        playerState.showSkipSettings ||
        playerState.showDanmakuSearch ||
        playerState.showLongPressSpeedSettings
    }

    var body: some View {
        GeometryReader { geo in
            Color.clear.contentShape(Rectangle())
                .onTapGesture {
                    // 锁定状态下也允许 tap，由父视图决定是否显示锁定按钮
                    onTap()
                }
                .gesture(DragGesture(minimumDistance: 14)
                    .onChanged { value in
                        guard !playerState.isOrientationLocked else { return }
                        // 长按倍速期间禁用拖拽手势
                        if playerState.showLongPressSpeedHint { return }
                        // 修复: 弹窗显示时禁用手势，防止控制面板卡死
                        if isAnyPopupPresented { return }
                        if !isDragging {
                            isDragging = true
                            startBrightness = playerState.brightness
                            startVolume = playerState.volume
                            startSeekTime = playerState.currentTime
                            let vertical = abs(value.translation.height)
                            let horizontal = abs(value.translation.width)
                            if !playerState.isPortrait,
                               playerState.duration.isFinite,
                               playerState.duration > 0,
                               horizontal > 24,
                               horizontal > vertical * 1.15 {
                                gestureMode = .seek
                                playerState.showControls = true
                                playerState.isSeeking = true
                                playerState.seekPreviewTime = playerState.currentTime
                            } else if vertical < 18 || horizontal > vertical * 0.75 {
                                gestureMode = .ignored
                            } else {
                                gestureMode = value.startLocation.x < geo.size.width / 2 ? .brightness : .volume
                            }
                        }
                        guard gestureMode != .ignored else { return }
                        if gestureMode == .seek {
                            let maxSeekDelta = min(max(playerState.duration * 0.12, 60), 300)
                            let deltaSeconds = Double(value.translation.width / max(geo.size.width, 1)) * maxSeekDelta
                            let target = max(0, min(playerState.duration, startSeekTime + deltaSeconds))
                            playerState.seekPreviewTime = target
                            playerState.currentTime = target
                            return
                        }
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
                        if gestureMode == .seek {
                            playerState.seek(to: playerState.seekPreviewTime)
                        }
                        isDragging = false
                        gestureMode = nil
                    }
                )
                // 长按倍速手势：长按 0.8 秒触发，松手恢复
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.8)
                        .onChanged { pressed in
                            if pressed {
                                guard !playerState.isOrientationLocked else { return }
                                guard !isAnyPopupPresented else { return }
                                playerState.startLongPressSpeed()
                            }
                        }
                        .onEnded { _ in
                            playerState.endLongPressSpeed()
                        }
                )
        }
    }
}

struct DanmakuOverlayViewV2: UIViewRepresentable {
    @Binding var showDanmaku: Bool
    let opacity: Double
    let fontSize: CGFloat
    let area: Double
    let currentTime: Double
    let items: [DanmakuRenderItem]

    func makeUIView(context: Context) -> DanmakuUIView {
        let view = DanmakuUIView()
        view.danmakuArea = area
        view.danmakuFontSize = fontSize
        view.danmakuOpacity = opacity
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: DanmakuUIView, context: Context) {
        uiView.danmakuArea = area
        uiView.danmakuFontSize = fontSize
        uiView.danmakuOpacity = opacity
        uiView.updateItems(items, currentTime: currentTime)
    }
}

// MARK: - 弹幕Layer对象池，复用避免每帧创建/销毁
private class DanmakuLayerPool {
    private var available: [CATextLayer] = []
    private var inUse: [Int: CATextLayer] = [:]
    private let maxPoolSize = 60

    func acquire(id: Int, fontSize: CGFloat, opacity: Double) -> CATextLayer {
        if let existing = inUse[id] { return existing }
        let textLayer: CATextLayer
        if let reused = available.popLast() {
            textLayer = reused
            textLayer.isHidden = false
            // 清除复用layer上的旧动画
            textLayer.removeAllAnimations()
        } else {
            textLayer = CATextLayer()
            textLayer.contentsScale = UIScreen.main.scale
            textLayer.shadowColor = UIColor.black.withAlphaComponent(0.5).cgColor
            textLayer.shadowOffset = CGSize(width: 1, height: 1)
            textLayer.shadowRadius = 1
            textLayer.shadowOpacity = 1
        }
        inUse[id] = textLayer
        return textLayer
    }

    func releaseAll() {
        for (_, textLayer) in inUse {
            textLayer.removeAllAnimations()
            textLayer.isHidden = true
            if available.count < maxPoolSize {
                available.append(textLayer)
            } else {
                textLayer.removeFromSuperlayer()
            }
        }
        inUse.removeAll()
    }

    func releaseUnused(visibleIDs: Set<Int>) {
        let toRelease = inUse.filter { !visibleIDs.contains($0.key) }
        for (id, textLayer) in toRelease {
            textLayer.removeAllAnimations()
            textLayer.isHidden = true
            if available.count < maxPoolSize {
                available.append(textLayer)
            } else {
                textLayer.removeFromSuperlayer()
            }
            inUse.removeValue(forKey: id)
        }
    }

    func getInUse(id: Int) -> CATextLayer? {
        return inUse[id]
    }
}

// MARK: - UIKit 原生弹幕渲染视图，使用 CABasicAnimation 实现60fps平滑滚动
class DanmakuUIView: UIView {
    var danmakuArea: Double = 0.25
    var danmakuFontSize: CGFloat = 16
    var danmakuOpacity: Double = 1.0

    private var layerPool = DanmakuLayerPool()
    /// 记录已添加动画的item ID，避免重复添加
    private var animatedItemIDs = Set<Int>()
    private var cachedFont: UIFont?
    /// 记录每个item的创建时间（用于计算动画偏移）
    private var itemStartTimes: [Int: Double] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func updateItems(_ items: [DanmakuRenderItem], currentTime: Double) {
        let screenW = bounds.width
        guard screenW > 0 else { return }

        let laneHeight = danmakuFontSize + 22
        let maxAreaHeight = bounds.height * danmakuArea

        // 缓存字体
        if cachedFont == nil || cachedFont?.pointSize != danmakuFontSize {
            cachedFont = UIFont.systemFont(ofSize: danmakuFontSize, weight: .semibold)
        }

        var visibleIDs = Set<Int>()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        for item in items {
            let progress = min(max((currentTime - item.time) / item.duration, 0), 1)
            let yPos = CGFloat(item.lane) * laneHeight + 20
            guard yPos < maxAreaHeight && progress >= 0 && progress < 1 else { continue }

            visibleIDs.insert(item.id)

            let textWidth = max(80, CGFloat(item.content.count) * danmakuFontSize * (item.content.isASCII ? 0.6 : 0.72))
            let textLayer = layerPool.acquire(id: item.id, fontSize: danmakuFontSize, opacity: danmakuOpacity)

            // 设置文字内容和样式（仅在首次添加时）
            if !animatedItemIDs.contains(item.id) {
                textLayer.string = item.content
                textLayer.font = cachedFont
                textLayer.fontSize = danmakuFontSize
                let color = UIColor(
                    red: Double((item.color >> 16) & 0xff) / 255.0,
                    green: Double((item.color >> 8) & 0xff) / 255.0,
                    blue: Double(item.color & 0xff) / 255.0,
                    alpha: danmakuOpacity
                )
                textLayer.foregroundColor = color.cgColor

                let layerWidth = textWidth + 40
                let layerHeight = danmakuFontSize + 10
                textLayer.bounds = CGRect(x: 0, y: 0, width: layerWidth, height: layerHeight)

                // position 是 layer 的中心点，不是左上角
                // 起始：左边缘对齐屏幕右边缘（完全在屏外右侧）
                let startPos = CGPoint(x: screenW + layerWidth / 2, y: yPos + layerHeight / 2)
                // 结束：右边缘对齐屏幕左边缘（完全在屏外左侧）
                let endPos = CGPoint(x: -layerWidth / 2, y: yPos + layerHeight / 2)

                // 设置模型位置为起始位置（动画结束后会回到此处，但此时 layer 已被移除）
                textLayer.position = startPos

                if textLayer.superlayer == nil {
                    self.layer.addSublayer(textLayer)
                }

                // 创建位置动画：由 Core Animation 在 GPU 上以 60fps 自动插值
                let animation = CABasicAnimation(keyPath: "position")
                animation.fromValue = NSValue(cgPoint: startPos)
                animation.toValue = NSValue(cgPoint: endPos)
                animation.duration = item.duration
                // 如果弹幕应该在过去某时刻出现，用 beginTime 偏移让动画从正确位置开始
                animation.beginTime = CACurrentMediaTime() - (currentTime - item.time)
                animation.isRemovedOnCompletion = true
                animation.fillMode = .removed

                textLayer.add(animation, forKey: "danmaku_scroll")

                animatedItemIDs.insert(item.id)
            }
        }

        CATransaction.commit()

        // 清理不再可见的item
        let removedIDs = animatedItemIDs.subtracting(visibleIDs)
        for id in removedIDs {
            animatedItemIDs.remove(id)
        }
        layerPool.releaseUnused(visibleIDs: visibleIDs)
    }

    /// 清除所有弹幕（切换视频时调用）
    func clearAll() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layerPool.releaseAll()
        animatedItemIDs.removeAll()
        itemStartTimes.removeAll()
        CATransaction.commit()
    }
}

extension String {
    var isASCII: Bool {
        allSatisfy { $0.isASCII }
    }
}

struct EpisodePickerPanelV2: View {
    @ObservedObject var playerState: PlayerState
    @Binding var isPresented: Bool
    var isPortrait: Bool = true
    @Binding var isReversed: Bool
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

    private var sortedEpisodes: [EpisodeItem] {
        isReversed ? Array(playerState.episodeItems.reversed()) : playerState.episodeItems
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
        ForEach(sortedEpisodes) { episode in
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
