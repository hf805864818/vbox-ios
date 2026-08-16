import SwiftUI
import UIKit
import Combine

// MARK: - 福利首页（仅保留 MissAV 和 香蕉秀）
struct WelfareHomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var ybox = YBoxService2.shared
    @StateObject private var remoteConfigStore = WelfarePlatformConfigStore.shared
    @State private var selectedTab: WelfareTab = .video
    @State private var isEditMode = false
    /// 排序后的平台列表（按 category 分别缓存）
    /// - 远程源模式：元素为 YBoxPlatform2（由 remoteConfigStore 转换而来）
    /// - 兼容模式：元素为 YBoxPlatform2（由 ybox.categories 转换而来）
    @State private var orderedPlatforms: [WelfareTab: [YBoxPlatform2]] = [:]
    @State private var navigatePlatformID: String?

    // 拖动排序边缘自动滚动
    @State private var autoScrollDirection: CGFloat = 0 // -1 上 / 0 停 / 1 下
    @State private var autoScrollTimer: CADisplayLink?
    @State private var autoScrollTarget: AutoScrollTarget?
    @State private var scrollViewRef: UIScrollView?
    private let edgeThreshold: CGFloat = 80 // 距边缘多少 pt 触发自动滚动

    private enum WelfareTab: String, CaseIterable {
        case video = "视频"
        case live = "直播"
        case comic = "漫画"

        var icon: String {
            switch self {
            case .video: return "play.rectangle.fill"
            case .live: return "antenna.radiowaves.left.and.right"
            case .comic: return "books.vertical.fill"
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Tab切换栏
                HStack(spacing: 0) {
                    ForEach(WelfareTab.allCases, id: \.self) { tab in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                selectedTab = tab
                            }
                        }) {
                            VStack(spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: tab.icon)
                                        .font(.system(size: 14))
                                    Text(tab.rawValue)
                                        .font(.system(size: 15, weight: selectedTab == tab ? .bold : .regular))
                                }
                                .foregroundColor(selectedTab == tab
                                    ? .white
                                    : (settings.usesVisualSkin ? .white.opacity(0.6) : .primary.opacity(0.5))
                                )
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(selectedTab == tab ?
                                          themeGradient(for: tab)
                                          : LinearGradient(colors: [Color.clear], startPoint: .leading, endPoint: .trailing))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // 编辑模式提示
                if isEditMode {
                    HStack {
                        Text("长按卡片拖动排序").font(.system(size: 12)).foregroundColor(.secondary)
                        Spacer()
                        Button("完成") { withAnimation { isEditMode = false; saveOrder() } }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                }

                // 内容区域
                TabView(selection: $selectedTab) {
                    platformGrid(for: .video).tag(WelfareTab.video)
                    platformGrid(for: .live).tag(WelfareTab.live)
                    platformGrid(for: .comic).tag(WelfareTab.comic)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .background(navigationProxy)
            .background(settings.usesVisualSkin ? Color.clear.ignoresSafeArea() : Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationBarHidden(true)
            .onAppear { loadOrder() }
        }
    }

    /// 统一的隐藏跳转入口。
    private var navigationProxy: some View {
        NavigationLink(
            destination: Group {
                if let platform = navigationPlatform {
                    destinationView(for: platform)
                } else {
                    EmptyView()
                }
            },
            isActive: Binding(
                get: { navigatePlatformID != nil },
                set: { active in
                    if !active { navigatePlatformID = nil }
                }
            )
        ) {
            EmptyView()
        }
        .hidden()
    }

    private var navigationPlatform: YBoxPlatform2? {
        for tab in WelfareTab.allCases {
            if let platform = currentOrderedPlatforms(for: tab).first(where: { $0.id == navigatePlatformID }) {
                return platform
            }
        }
        return nil
    }

    // MARK: - 平台网格（长按进入排序）
    private func platformGrid(for tab: WelfareTab) -> some View {
        let platforms = currentOrderedPlatforms(for: tab)

        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                if platforms.isEmpty {
                    VStack(spacing: 12) {
                        Spacer().frame(height: 60)
                        Image(systemName: "square.grid.3x3")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("暂无平台")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4),
                        spacing: 16
                    ) {
                        ForEach(Array(platforms.enumerated()), id: \.element.id) { index, platform in
                            if isEditMode {
                                PlatformSortableCard(
                                    platform: platform,
                                    index: index,
                                    totalCount: platforms.count,
                                    gradient: platformGradient(platform.name),
                                    onMove: { fromIdx, toIdx in
                                        movePlatform(from: fromIdx, to: toIdx, tab: tab)
                                    },
                                    onEdgeProximity: { direction in
                                        handleEdgeProximity(
                                            direction: direction,
                                            proxy: proxy
                                        )
                                    }
                                )
                                .id(platform.id)
                            } else {
                                PlatformIconCard(platform: platform, gradient: platformGradient(platform.name))
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        navigatePlatformID = platform.id
                                    }
                                    .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 12) {
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        navigatePlatformID = nil
                                        withAnimation { isEditMode = true }
                                    }
                                    .frame(width: 72, height: 86)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 100)
                    .background(
                        ScrollViewDetector { scrollView in
                            scrollViewRef = scrollView
                        }
                    )
                }
            }
            .onChange(of: isEditMode) { editing in
                if !editing {
                    stopAutoScroll()
                }
            }
        }
    }

    // MARK: - 边缘自动滚动逻辑

    private func handleEdgeProximity(
        direction: CGFloat,
        proxy: ScrollViewProxy
    ) {
        guard direction != 0 else {
            stopAutoScroll()
            return
        }

        // direction 同时表示方向和速度（-1.0 ~ 1.0，绝对值越大越快）
        // 方向改变或速度变化较大时，更新自动滚动
        let currentSpeed = abs(autoScrollDirection)
        let newSpeed = abs(direction)
        let directionChanged = (autoScrollDirection > 0) != (direction > 0)
        let speedChanged = abs(currentSpeed - newSpeed) > 0.2

        if directionChanged || autoScrollDirection == 0 {
            autoScrollDirection = direction
            startAutoScroll(direction: direction)
        } else if speedChanged {
            autoScrollDirection = direction
            updateAutoScrollSpeed(direction: direction)
        }
    }

    private func startAutoScroll(direction: CGFloat) {
        stopAutoScroll()

        // 基础速度 3pt/帧，乘以速度因子（0.3~1.0）
        let baseSpeed: CGFloat = 3.0
        let speedFactor = max(0.3, abs(direction))
        let actualSpeed = baseSpeed * speedFactor
        let actualDirection: CGFloat = direction > 0 ? 1 : -1

        autoScrollTarget = AutoScrollTarget(
            direction: actualDirection,
            speed: actualSpeed,
            scrollViewRef: scrollViewRef
        )
        autoScrollTimer = CADisplayLink(target: autoScrollTarget!, selector: #selector(AutoScrollTarget.tick(_:)))
        autoScrollTimer?.add(to: .main, forMode: .common)
    }

    private func updateAutoScrollSpeed(direction: CGFloat) {
        guard let target = autoScrollTarget else { return }
        let baseSpeed: CGFloat = 3.0
        let speedFactor = max(0.3, abs(direction))
        target.speed = baseSpeed * speedFactor
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollDirection = 0
    }

    private func destinationView(for platform: YBoxPlatform2) -> AnyView {
        // 阶段3 改造：完全走 WelfarePlatformRouter 统一路由
        if let crawlerId = platform.crawlerPlatformId,
           let remotePlatform = remoteConfigStore.platform(forKey: crawlerId) {
            return AnyView(
                WelfarePlatformRouter.shared
                    .makeDestinationView(for: remotePlatform, settings: settings)
                    .environmentObject(settings)
            )
        }

        return AnyView(
            VStack(spacing: 16) {
                Image(systemName: "giftcard")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("请开启福利远程源")
                    .font(.system(size: 16, weight: .semibold))
                Text("福利平台已全部迁移到远程源配置")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
    }

    // MARK: - 平台数据过滤
    private func filteredPlatforms(for tab: WelfareTab) -> [YBoxPlatform2] {
        let categoryKey: String = {
            switch tab {
            case .video: return "video"
            case .live:  return "live"
            case .comic: return "comic"
            }
        }()

        if remoteConfigStore.switchEnabled {
            let items = remoteConfigStore.platforms(in: RemoteWelfareCategory(rawValue: categoryKey) ?? .video)
            return items.map { p in
                YBoxPlatform2(
                    name: p.name,
                    icon: p.icon,
                    type: tab == .live ? .live : (tab == .comic ? .comic : .video),
                    baseURL: p.primaryHost,
                    desc: p.desc,
                    crawlerPlatformId: p.platformKey
                )
            }
        }

        for c in ybox.categories {
            if c.name == tab.rawValue { return c.platforms }
        }
        return []
    }

    // MARK: - 颜色工具
    private func tabGradient(_ tab: WelfareTab) -> [Color] {
        switch tab {
        case .video: return [Color(hex: "3B82F6"), Color(hex: "2563EB")]
        case .live:  return [Color(hex: "F97316"), Color(hex: "EA580C")]
        case .comic: return [Color(hex: "8B5CF6"), Color(hex: "7C3AED")]
        }
    }

    private func themeGradient(for tab: WelfareTab) -> LinearGradient {
        let colors: [Color]
        if settings.usesLiquidSkin {
            colors = [Color(hex: "38BDF8"), Color(hex: "0EA5E9")]
        } else if settings.usesFrostedSkin {
            colors = [Color(hex: "7C3AED"), Color(hex: "A855F7")]
        } else if settings.usesVisualSkin {
            colors = [Color(hex: "6366F1"), Color(hex: "818CF8")]
        } else {
            colors = tabGradient(tab)
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    private func platformGradient(_ name: String) -> [Color] {
        let colorMap: [String: [Color]] = [
            "MissAV":       [Color(hex: "FD79A8"), Color(hex: "E84393")],
            "香蕉秀":        [Color(hex: "FFEAA7"), Color(hex: "FDCB6E")],
            "每日大乱斗":    [Color(hex: "FF6B35"), Color(hex: "D72638")],
            "每日大赛":      [Color(hex: "FFD700"), Color(hex: "FF8C00")],
            "神秘电影":      [Color(hex: "6C5CE7"), Color(hex: "A855F7")],
            "One平台":       [Color(hex: "10B981"), Color(hex: "059669")],
            "萝莉AV":        [Color(hex: "EC4899"), Color(hex: "BE185D")],
            "麻豆免费":       [Color(hex: "F59E0B"), Color(hex: "D97706")],
            "久久網":         [Color(hex: "06B6D4"), Color(hex: "0891B2")],
            "韩国色情电影":    [Color(hex: "DC2626"), Color(hex: "B91C1C")],
            "今日看料":        [Color(hex: "8B5CF6"), Color(hex: "7C3AED")],
            "黑料不打烊":      [Color(hex: "F97316"), Color(hex: "EA580C")],
            "通用吸瓜":        [Color(hex: "22C55E"), Color(hex: "16A34A")],
            "熊猫视频":        [Color(hex: "14B8A6"), Color(hex: "0D9488")],
            "4H视频":          [Color(hex: "EF4444"), Color(hex: "DC2626")],
            "FullHD":          [Color(hex: "3B82F6"), Color(hex: "2563EB")],
            "歪比":            [Color(hex: "8B5CF6"), Color(hex: "7C3AED")],
            "小鸭子看看":      [Color(hex: "F59E0B"), Color(hex: "D97706")],
            "香蕉视频":        [Color(hex: "FBBF24"), Color(hex: "F59E0B")],
        ]
        return colorMap[name, default: [Color(hex: "636E72"), Color(hex: "B2BEC3")]]
    }

    // MARK: - 排序逻辑

    private func currentOrderedPlatforms(for tab: WelfareTab) -> [YBoxPlatform2] {
        orderedPlatforms[tab] ?? filteredPlatforms(for: tab)
    }

    private func movePlatform(from source: Int, to destination: Int, tab: WelfareTab) {
        var list = currentOrderedPlatforms(for: tab)
        guard source >= 0, source < list.count, destination >= 0, destination < list.count else { return }
        let item = list.remove(at: source)
        list.insert(item, at: destination)
        orderedPlatforms[tab] = list
    }

    private func saveOrder() {
        var dict: [String: [String]] = [:]
        for tab in WelfareTab.allCases {
            let list = orderedPlatforms[tab] ?? filteredPlatforms(for: tab)
            dict[tab.rawValue] = list.map { $0.id }
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: "welfare_platform_order")
        }
    }

    private func loadOrder() {
        if let data = UserDefaults.standard.data(forKey: "welfare_platform_order"),
           let dict = try? JSONDecoder().decode([String: [String]].self, from: data) {
            for tab in WelfareTab.allCases {
                let saved = dict[tab.rawValue] ?? []
                if !saved.isEmpty {
                    let all = filteredPlatforms(for: tab)
                    let ordered = all.sorted { a, b in
                        let ai = saved.firstIndex(of: a.id) ?? Int.max
                        let bi = saved.firstIndex(of: b.id) ?? Int.max
                        return ai < bi
                    }
                    if ordered.count == all.count { orderedPlatforms[tab] = ordered }
                }
            }
        }
    }
}

// MARK: - 自动滚动 Target（用于 CADisplayLink）
class AutoScrollTarget: NSObject {
    let direction: CGFloat
    var speed: CGFloat  // 可变，支持动态调整速度
    weak var scrollViewRef: UIScrollView?

    init(direction: CGFloat, speed: CGFloat, scrollViewRef: UIScrollView?) {
        self.direction = direction
        self.speed = speed
        self.scrollViewRef = scrollViewRef
        super.init()
    }

    @objc func tick(_ displayLink: CADisplayLink) {
        guard let scrollView = scrollViewRef else {
            displayLink.invalidate()
            return
        }

        let offset = scrollView.contentOffset
        let contentHeight = scrollView.contentSize.height
        let viewHeight = scrollView.bounds.height

        var newY = offset.y + direction * speed

        // 边界检查
        newY = max(0, min(newY, contentHeight - viewHeight + scrollView.contentInset.bottom))

        if newY != offset.y {
            scrollView.contentOffset = CGPoint(x: offset.x, y: newY)
        }
    }
}

// MARK: - ScrollView 探测器
struct ScrollViewDetector: UIViewRepresentable {
    var onFound: (UIScrollView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            if let scrollView = uiView.superview(ofType: UIScrollView.self) {
                onFound(scrollView)
            }
        }
    }
}

extension UIView {
    func superview<T>(ofType type: T.Type) -> T? {
        var current = superview
        while let view = current {
            if let typed = view as? T {
                return typed
            }
            current = view.superview
        }
        return nil
    }
}

// MARK: - 平台入口图标卡片（正常模式）
struct PlatformIconCard: View {
    let platform: YBoxPlatform2
    let gradient: [Color]

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                Image(systemName: platform.icon).font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
            }
            Text(platform.name).font(.system(size: 11, weight: .medium)).foregroundColor(.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 72, height: 86)
    }
}

// MARK: - 可拖动排序卡片（纯 SwiftUI 实现）
struct PlatformSortableCard: View {
    let platform: YBoxPlatform2
    let index: Int
    let totalCount: Int
    let gradient: [Color]
    let onMove: (Int, Int) -> Void
    var onEdgeProximity: ((CGFloat) -> Void)? = nil

    // 拖动状态
    @State private var isDragging = false
    @State private var dragOffset: CGSize = .zero
    @State private var currentIndex: Int = 0
    @State private var cardGlobalY: CGFloat = 0

    // 震动反馈
    private let lightFeedback = UIImpactFeedbackGenerator(style: .light)
    private let mediumFeedback = UIImpactFeedbackGenerator(style: .medium)

    // 布局常量
    private let columns = 4
    private let cardWidth: CGFloat = 88   // 72 + 16 spacing
    private let cardHeight: CGFloat = 102 // 86 + 16 spacing

    var body: some View {
        GeometryReader { geo in
            CardContent(gradient: gradient, icon: platform.icon, name: platform.name)
                .frame(width: 72, height: 86)
                .offset(dragOffset)
                .scaleEffect(isDragging ? 1.15 : 1.0)
                .shadow(color: isDragging ? .black.opacity(0.3) : .clear,
                        radius: isDragging ? 10 : 0,
                        y: isDragging ? 5 : 0)
                .zIndex(isDragging ? 100 : 0)
                .onAppear {
                    cardGlobalY = geo.frame(in: .global).midY
                }
                .gesture(
                    // 长按进入拖动模式
                    LongPressGesture(minimumDuration: 0.4, maximumDistance: 30)
                        .onEnded { _ in
                            lightFeedback.prepare()
                            mediumFeedback.prepare()
                            lightFeedback.impactOccurred()
                            currentIndex = index
                            cardGlobalY = geo.frame(in: .global).midY
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                isDragging = true
                            }
                        }
                        .sequenced(before:
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard isDragging else { return }
                                    dragOffset = value.translation
                                    handleDragChange(
                                        translation: value.translation,
                                        currentGlobalY: cardGlobalY + value.translation.height
                                    )
                                }
                                .onEnded { _ in
                                    handleDragEnd()
                                }
                        )
                )
        }
        .frame(width: 72, height: 86)
        .animation(.easeInOut(duration: 0.2), value: isDragging)
    }

    private func handleDragChange(translation: CGSize, currentGlobalY: CGFloat) {
        let currentRow = currentIndex / columns
        let currentCol = currentIndex % columns

        let deltaRow = Int(round(translation.height / cardHeight))
        let deltaCol = Int(round(translation.width / cardWidth))

        var targetRow = currentRow + deltaRow
        var targetCol = currentCol + deltaCol

        targetCol = min(max(targetCol, 0), columns - 1)

        let totalRows = (totalCount + columns - 1) / columns
        targetRow = min(max(targetRow, 0), totalRows - 1)

        var targetIndex = targetRow * columns + targetCol
        targetIndex = min(max(targetIndex, 0), totalCount - 1)

        // 位置变化时触发轻震动（碰到卡片的手感）
        if targetIndex != currentIndex {
            lightFeedback.impactOccurred(intensity: 0.6)
            lightFeedback.prepare()
            onMove(currentIndex, targetIndex)
            currentIndex = targetIndex
        }

        // 边缘自动滚动检测（基于屏幕坐标）
        if let edgeProximity = onEdgeProximity, isDragging {
            let screenHeight = UIScreen.main.bounds.height
            let edgeMargin: CGFloat = 100  // 距屏幕边缘多少 pt 触发

            let distanceFromTop = currentGlobalY
            let distanceFromBottom = screenHeight - currentGlobalY

            if distanceFromTop < edgeMargin {
                // 越靠近顶部，滚动越快
                let speedFactor = max(0.3, 1 - distanceFromTop / edgeMargin)
                edgeProximity(-speedFactor)
            } else if distanceFromBottom < edgeMargin {
                let speedFactor = max(0.3, 1 - distanceFromBottom / edgeMargin)
                edgeProximity(speedFactor)
            } else {
                edgeProximity(0)
            }
        }
    }

    private func handleDragEnd() {
        onEdgeProximity?(0)
        mediumFeedback.impactOccurred()
        mediumFeedback.prepare()
        lightFeedback.prepare()

        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            isDragging = false
            dragOffset = .zero
        }
    }

    // MARK: - 卡片内容
    struct CardContent: View {
        let gradient: [Color]
        let icon: String
        let name: String

        var body: some View {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 52, height: 52)
                    Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
                }
                Text(name).font(.system(size: 11, weight: .medium)).foregroundColor(.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: 72, height: 86)
        }
    }
}
