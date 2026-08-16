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
    @State private var autoScrollTimer: Timer?
    private let edgeThreshold: CGFloat = 100 // 距边缘多少 pt 触发自动滚动

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
    /// 不再把 NavigationLink 放进每个 LazyVGrid 单元，避免隐藏导航控件参与网格布局导致图标错位。
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
                                    platform: platform, index: index, gradient: platformGradient(platform.name),
                                    onMove: { fromIdx, toIdx in movePlatform(from: fromIdx, to: toIdx, tab: tab) },
                                    onEnterEditMode: { withAnimation { isEditMode = true } },
                                    onEdgeProximity: { direction in
                                        handleEdgeProximity(direction: direction, proxy: proxy, platforms: platforms, currentIndex: index)
                                    }
                                )
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

    private func handleEdgeProximity(direction: CGFloat, proxy: ScrollViewProxy, platforms: [YBoxPlatform2], currentIndex: Int) {
        // direction: -1 靠近顶部 / 0 不靠近 / 1 靠近底部
        guard direction != 0 else {
            stopAutoScroll()
            return
        }

        // 方向变化时重启定时器
        if autoScrollDirection != direction {
            autoScrollDirection = direction
            startAutoScroll(direction: direction, proxy: proxy, platforms: platforms, currentIndex: currentIndex)
        }
    }

    private func startAutoScroll(direction: CGFloat, proxy: ScrollViewProxy, platforms: [YBoxPlatform2], currentIndex: Int) {
        stopAutoScroll()

        let cols = 4
        let scrollStep = 2 // 每次滚动2行

        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in
                // 用当前最新的排序数据查找实际位置（排序过程中 index 会变）
                let currentPlatformId = platforms[currentIndex].id
                let currentList = platforms
                guard let realIdx = currentList.firstIndex(where: { $0.id == currentPlatformId }) else {
                    stopAutoScroll()
                    return
                }

                let targetIdx: Int
                if direction < 0 {
                    // 向上滚动
                    targetIdx = max(0, realIdx - cols * scrollStep)
                } else {
                    // 向下滚动
                    targetIdx = min(currentList.count - 1, realIdx + cols * scrollStep)
                }

                guard targetIdx >= 0, targetIdx < currentList.count, targetIdx != realIdx else {
                    stopAutoScroll()
                    return
                }

                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(currentList[targetIdx].id, anchor: direction < 0 ? .top : .bottom)
                }
            }
        }
        RunLoop.main.add(autoScrollTimer!, forMode: .common)
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollDirection = 0
    }

    private func destinationView(for platform: YBoxPlatform2) -> AnyView {
        // 阶段3 改造：完全走 WelfarePlatformRouter 统一路由
        // 1. 优先查远程源（YBoxPlatform2.crawlerPlatformId 即 platformKey）
        if let crawlerId = platform.crawlerPlatformId,
           let remotePlatform = remoteConfigStore.platform(forKey: crawlerId) {
            return AnyView(
                WelfarePlatformRouter.shared
                    .makeDestinationView(for: remotePlatform, settings: settings)
                    .environmentObject(settings)
            )
        }

        // 2. 兼容模式：远程源未开启时不展示任何平台，提示用户开启远程源
        // 所有福利平台均由远程源统一配置驱动，本地不再硬编码路由
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

        // 阶段3 改造：远程源模式从 WelfarePlatformConfigStore 读，兼容模式从 ybox.categories 读
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

        // 兼容模式：仅返回 ybox.categories 里的平台（不写死白名单）
        for c in ybox.categories {
            if c.name == tab.rawValue { return c.platforms }
        }
        return []
    }

    // MARK: - 颜色工具
    private func tabGradient(_ tab: WelfareTab) -> [Color] {
        // 视频→蓝 / 直播→橙 / 漫画→紫，三者选中时颜色各不同
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

// MARK: - 可拖动排序卡片
struct PlatformSortableCard: View {
    let platform: YBoxPlatform2
    let index: Int
    let gradient: [Color]
    let onMove: (Int, Int) -> Void
    let onEnterEditMode: () -> Void
    var onEdgeProximity: ((CGFloat) -> Void)? = nil

    @State private var offset = CGSize.zero
    @State private var isPickedUp = false
    @State private var lastTargetRow: Int = -1
    @State private var lastTargetCol: Int = -1
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                Image(systemName: platform.icon).font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
            }.overlay(Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2))
            Text(platform.name).font(.system(size: 11, weight: .medium)).foregroundColor(.primary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 72, height: 86)
        .scaleEffect(isPickedUp ? 1.15 : 1.0)
        .shadow(color: isPickedUp ? Color.black.opacity(0.3) : Color.clear, radius: 10, x: 0, y: 5)
        .offset(offset)
        .zIndex(isPickedUp ? 999 : 0)
        .gesture(
            // maximumDistance: 长按等待期间手指移动超过 10pt 即判定为滚动，让 ScrollView 接管
            LongPressGesture(minimumDuration: 0.4, maximumDistance: 10)
                .onEnded { _ in
                    isPickedUp = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                // minimumDistance: 长按成功后也需移动 15pt 才算拖动，避免误触
                .sequenced(before: DragGesture(minimumDistance: 15, coordinateSpace: .global)
                    .onChanged { value in
                        // 检测边缘 proximity（全局坐标），通知父视图触发自动滚动
                        let globalY = value.location.y
                        let screenH = UIScreen.main.bounds.height
                        let threshold: CGFloat = 100
                        if globalY < threshold {
                            // 靠近顶部
                            onEdgeProximity?(-1)
                        } else if globalY > screenH - threshold {
                            // 靠近底部
                            onEdgeProximity?(1)
                        } else {
                            // 不在边缘区域
                            onEdgeProximity?(0)
                        }
                    }
                )
                .onChanged { value in
                    switch value {
                    case .second(_, let drag?):
                        offset = drag.translation
                        // 跨越卡片时震动反馈
                        let cols = 4
                        let currentRow = index / cols
                        let currentCol = index % cols
                        let targetRow = currentRow + Int(round(drag.translation.height / 102))
                        let targetCol = min(max(currentCol + Int(round(drag.translation.width / 88)), 0), cols - 1)

                        // 初始化上一次目标位置
                        if lastTargetRow == -1 {
                            lastTargetRow = currentRow
                            lastTargetCol = currentCol
                        }

                        // 行或列发生变化时触发震动（即"碰到"了其他卡片）
                        if targetRow != lastTargetRow || targetCol != lastTargetCol {
                            feedbackGenerator.impactOccurred(intensity: 0.6)
                            lastTargetRow = targetRow
                            lastTargetCol = targetCol
                        }
                    default:
                        break
                    }
                }
                .onEnded { value in
                    // 停止自动滚动
                    onEdgeProximity?(0)
                    // 重置位置追踪
                    lastTargetRow = -1
                    lastTargetCol = -1

                    if case .second(_, let drag?) = value {
                        let cols = 4
                        let currentRow = index / cols
                        let currentCol = index % cols
                        let newRow = currentRow + Int(round(drag.translation.height / 102))
                        let newCol = min(max(currentCol + Int(round(drag.translation.width / 88)), 0), cols - 1)
                        let newIndex = newRow * cols + newCol
                        if newIndex >= 0, newIndex < 100, newIndex != index {
                            onMove(index, newIndex)
                            // 松手落位时再来一次稍重的震动
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        }
                    }
                    isPickedUp = false
                    withAnimation(.spring()) { offset = .zero }
                }
        )
    }
}
