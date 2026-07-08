import SwiftUI

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
        } else if platform.name == "每日大乱斗" {
            return AnyView(DailyBattleMainView(platform: platform))
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
        // 仅保留 MissAV、香蕉秀 和 每日大乱斗
        return all.filter { $0.name == "MissAV" || $0.name == "香蕉秀" || $0.name == "每日大乱斗" }
    }

    // MARK: - 颜色工具
    private func tabGradient(_ tab: WelfareTab) -> [Color] {
        // 统一使用应用主题色，避免突兀的红色渐变
        return [Color.accentColor, Color.accentColor.opacity(0.7)]
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
