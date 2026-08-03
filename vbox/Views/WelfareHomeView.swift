import SwiftUI
import UIKit

// MARK: - 福利首页（仅保留 MissAV 和 香蕉秀）
struct WelfareHomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var ybox = YBoxService2.shared
    @State private var selectedTab: WelfareTab = .video
    @State private var isEditMode = false
    @State private var orderedPlatforms: [WelfareTab: [YBoxPlatform2]] = [:]
    @State private var navigatePlatformID: String?

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
                        Text("长按进入排序模式").font(.system(size: 12)).foregroundColor(.secondary)
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
            .background(settings.usesVisualSkin ? Color.clear.ignoresSafeArea() : Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationBarHidden(true)
            .onAppear { loadOrder() }
        }
    }

    // MARK: - 平台网格（长按进入排序）
    private func platformGrid(for tab: WelfareTab) -> some View {
        let platforms = currentOrderedPlatforms(for: tab)

        return ScrollView(showsIndicators: false) {
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
                                onEnterEditMode: { withAnimation { isEditMode = true } }
                            )
                        } else {
                            NavigationLink(
                                destination: destinationView(for: platform),
                                tag: platform.id,
                                selection: $navigatePlatformID
                            ) {
                                PlatformIconCard(platform: platform, gradient: platformGradient(platform.name))
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(
                                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    navigatePlatformID = nil
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        withAnimation { isEditMode = true }
                                    }
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
        }
    }

    private func destinationView(for platform: YBoxPlatform2) -> some View {
        if platform.name == "MissAV" {
            return AnyView(MissAVHomeView().environmentObject(settings))
        } else if platform.name == "每日大乱斗" || platform.name == "每日大赛" {
            return AnyView(DailyBattleMainView(platform: platform))
        } else if platform.name == "神秘电影" {
            return AnyView(MysteryMovieMainView(platform: platform))
        } else if platform.name == "色播聚合" {
            return AnyView(SBAggregationView(platform: platform))
        } else if platform.name == "四虎视频" {
            return AnyView(SihuVideoHomeView(platform: platform))
        } else if platform.name == "香肠派对" {
            return AnyView(XCPHomeView(platform: platform))
        } else if platform.name == "One平台" {
            return AnyView(OnePlatformHomeView(platform: platform))
        } else if platform.name == "麻豆平台" {
            return AnyView(MDTVHomeView(platform: platform))
        } else if platform.name == "萝莉AV" {
            return AnyView(LuoliAVHomeView())
        } else if platform.name == "麻豆免费" {
            return AnyView(MadouFreeHomeView())
        } else if platform.name == "久久網" {
            return AnyView(JiujiuHomeView())
        } else if platform.name == "韩国色情电影" {
            return AnyView(KoreanPornHomeView())
        } else if platform.name == "今日看料" {
            return AnyView(KanliaoHomeView())
        } else if platform.name == "黑料不打烊" {
            return AnyView(HeiliaoHomeView())
        } else if platform.name == "通用吸瓜" {
            return AnyView(XiguaMainView(platform: platform))
        } else if platform.name == "熊猫视频" {
            return AnyView(FuliPlatformMainView(platform: platform, service: PandaVideoService.shared))
        } else if platform.name == "4H视频" {
            return AnyView(FuliPlatformMainView(platform: platform, service: FourHVideoService.shared))
        } else if platform.name == "FullHD" {
            return AnyView(FuliPlatformMainView(platform: platform, service: FullHDService.shared))
        } else if platform.name == "香蕉视频" {
            return AnyView(FuliPlatformMainView(platform: platform, service: BananaVideoService.shared))
        } else {
            return AnyView(YBoxXjspMainView(platform: platform))
        }
    }

    // MARK: - 平台数据过滤
    private func filteredPlatforms(for tab: WelfareTab) -> [YBoxPlatform2] {
        let all: [YBoxPlatform2] = {
            for c in ybox.categories {
                if c.name == tab.rawValue { return c.platforms }
            }
            return []
        }()
        // 仅保留 MissAV、香蕉秀、每日大乱斗、每日大赛 和 神秘电影
        return all.filter { $0.name == "MissAV" || $0.name == "香蕉秀" || $0.name == "每日大乱斗" || $0.name == "每日大赛" || $0.name == "神秘电影" || $0.name == "四虎视频" || $0.name == "香肠派对" || $0.name == "色播聚合" || $0.name == "One平台" || $0.name == "麻豆平台" || $0.name == "萝莉AV" || $0.name == "麻豆免费" || $0.name == "久久網" || $0.name == "韩国色情电影" || $0.name == "今日看料" || $0.name == "黑料不打烊" || $0.name == "通用吸瓜" || $0.name == "熊猫视频" || $0.name == "4H视频" || $0.name == "FullHD" || $0.name == "香蕉视频" }
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

    @State private var offset = CGSize.zero

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
        .scaleEffect(offset != .zero ? 1.1 : 1.0)
        .offset(offset)
        .zIndex(offset != .zero ? 999 : 0)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if offset == .zero { onEnterEditMode() }
                    offset = value.translation
                }
                .onEnded { value in
                    let cols = 4
                    let currentRow = index / cols; let currentCol = index % cols
                    let newRow = currentRow + Int(round(value.translation.height / 102))
                    let newCol = min(max(currentCol + Int(round(value.translation.width / 88)), 0), cols - 1)
                    let newIndex = newRow * cols + newCol
                    if newIndex >= 0, newIndex < 100, newIndex != index { onMove(index, newIndex) }
                    withAnimation(.spring()) { offset = .zero }
                }
        )
    }
}
