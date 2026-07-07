import SwiftUI

// MARK: - 福利首页（视频/直播/漫画 Tab切换 + 4列App图标 + 长按排序）

struct WelfareHomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var ybox = YBoxService2.shared
    @State private var selectedTab: WelfareTab = .video
    @State private var isEditMode = false
    @State private var orderedPlatforms: [WelfareTab: [YBoxPlatform2]] = [:]

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
                // 顶部导航栏
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("福利")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(.primary)
                    }
                    Spacer()
                    NavigationLink(destination: WelfareDomainSettingsView()
                        .environmentObject(settings)) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Tab切换栏
                HStack(spacing: 0) {
                    ForEach(WelfareTab.allCases, id: \.self) { tab in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                selectedTab = tab
                                isEditMode = false
                            }
                        }) {
                            VStack(spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: tab.icon)
                                        .font(.system(size: 14))
                                    Text(tab.rawValue)
                                        .font(.system(size: 15, weight: selectedTab == tab ? .bold : .regular))
                                }
                                .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.45))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(selectedTab == tab ?
                                          LinearGradient(colors: tabGradient(tab), startPoint: .leading, endPoint: .trailing)
                                          : LinearGradient(colors: [Color.clear], startPoint: .leading, endPoint: .trailing))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                // 编辑模式提示
                if isEditMode {
                    HStack {
                        Text("拖动卡片交换位置")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("完成") {
                            withAnimation { isEditMode = false }
                            saveOrder()
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(tabGradient(selectedTab)[0])
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
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationBarHidden(true)
            .onAppear { loadOrder() }
        }
    }

    // MARK: - 平台网格（4列App图标风格）

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
                            // 编辑模式：可拖动排序的卡片
                            PlatformSortableCard(
                                platform: platform,
                                index: index,
                                isEditMode: isEditMode,
                                gradient: platformGradient(platform.name),
                                onMove: { fromIndex, toIndex in
                                    movePlatform(from: fromIndex, to: toIndex, tab: tab)
                                },
                                onEnterEditMode: {
                                    withAnimation { isEditMode = true }
                                }
                            )
                        } else {
                            // 正常模式：导航卡片
                            let isSebo = platform.name == "色播聚合"
                            let isPanda = platform.name == "Pandalive"
                            let destination: AnyView = isSebo ? AnyView(YBoxLiveSourceListView().environmentObject(settings))
                                : isPanda ? AnyView(YBoxLiveSourceListView().environmentObject(settings))
                                : AnyView(YBoxCrawlerContentView(platform: platform))
                            NavigationLink(destination: destination) {
                                PlatformIconCard(
                                    platform: platform,
                                    isEditMode: false,
                                    gradient: platformGradient(platform.name)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
        }
    }

    // MARK: - 排序逻辑

    private func currentOrderedPlatforms(for tab: WelfareTab) -> [YBoxPlatform2] {
        orderedPlatforms[tab] ?? filteredPlatforms(for: tab)
    }

    private func filteredPlatforms(for tab: WelfareTab) -> [YBoxPlatform2] {
        let typeMap: [WelfareTab: YBoxPlatform2.PlatformType2] = [
            .video: .video, .live: .live, .comic: .comic
        ]
        guard let pt = typeMap[tab] else { return [] }
        let all: [YBoxPlatform2] = {
            for c in ybox.categories {
                if c.name == tab.rawValue { return c.platforms }
            }
            return []
        }()
        return all.filter { $0.type == pt || pt == .video }
    }

    private func movePlatform(from source: Int, to destination: Int, tab: WelfareTab) {
        var list = currentOrderedPlatforms(for: tab)
        guard source >= 0, source < list.count, destination >= 0, destination < list.count else { return }
        let item = list.remove(at: source)
        list.insert(item, at: destination)
        orderedPlatforms[tab] = list
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
                    if ordered.count == all.count {
                        orderedPlatforms[tab] = ordered
                    }
                }
            }
        }
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

    // MARK: - 颜色工具

    private func tabGradient(_ tab: WelfareTab) -> [Color] {
        switch tab {
        case .video: return [Color(hex: "E11D48"), Color(hex: "F43F5E")]
        case .live: return [Color(hex: "7C3AED"), Color(hex: "A855F7")]
        case .comic: return [Color(hex: "059669"), Color(hex: "34D399")]
        }
    }

    private func platformGradient(_ name: String) -> [Color] {
        let colorMap: [String: [Color]] = [
            "PigAV":        [Color(hex: "FF6B9D"), Color(hex: "C44569")],
            "JAV36":        [Color(hex: "54A0FF"), Color(hex: "2E86DE")],
            "VHUB":         [Color(hex: "A29BFE"), Color(hex: "6C5CE7")],
            "TOPTV":        [Color(hex: "FECA57"), Color(hex: "FF9F43")],
            "四虎视频":      [Color(hex: "FF4757"), Color(hex: "FF6B81")],
            "香蕉视频":      [Color(hex: "FFEAA7"), Color(hex: "FDCB6E")],
            "香肠派对":      [Color(hex: "FF6348"), Color(hex: "FF7F50")],
            "神秘电影":      [Color(hex: "2D3436"), Color(hex: "636E72")],
            "萝莉AV":        [Color(hex: "FD79A8"), Color(hex: "E84393")],
            "妲己":          [Color(hex: "E17055"), Color(hex: "D63031")],
            "熊猫视频":      [Color(hex: "00B894"), Color(hex: "00CEC9")],
            "FullHD":       [Color(hex: "0984E3"), Color(hex: "74B9FF")],
            "久久視頻":      [Color(hex: "6C5CE7"), Color(hex: "A29BFE")],
            "小鸭子看看":    [Color(hex: "FDCB6E"), Color(hex: "E17055")],
            "每日大乱斗":    [Color(hex: "E84393"), Color(hex: "FD79A8")],
            "每日大赛":      [Color(hex: "00CEC9"), Color(hex: "81ECEC")],
            "黑料不打烊":    [Color(hex: "2D3436"), Color(hex: "636E72")],
            "今日看料":      [Color(hex: "D63031"), Color(hex: "E17055")],
            "韩国色情电影":  [Color(hex: "E17055"), Color(hex: "FDCB6E")],
            "Pornhub":      [Color(hex: "FF6B9D"), Color(hex: "C44569")],
            "Xvideos":      [Color(hex: "6C5CE7"), Color(hex: "4834D4")],
            "色播聚合":      [Color(hex: "55EFC4"), Color(hex: "00B894")],
            "Pandalive":    [Color(hex: "81ECEC"), Color(hex: "00CEC9")],
            "MissAV":       [Color(hex: "FD79A8"), Color(hex: "E84393")],
            "香蕉秀":        [Color(hex: "FFEAA7"), Color(hex: "FDCB6E")],
            "1080视频":      [Color(hex: "0984E3"), Color(hex: "74B9FF")],
        ]
        return colorMap[name, default: [Color(hex: "636E72"), Color(hex: "B2BEC3")]]
    }
}

// MARK: - 平台入口图标卡片（正常模式）

struct PlatformIconCard: View {
    let platform: YBoxPlatform2
    let isEditMode: Bool
    let gradient: [Color]

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                Image(systemName: platform.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
            }
            Text(platform.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 72, height: 86)
    }
}

// MARK: - 可拖动排序卡片

struct PlatformSortableCard: View {
    let platform: YBoxPlatform2
    let index: Int
    let isEditMode: Bool
    let gradient: [Color]
    let onMove: (Int, Int) -> Void
    let onEnterEditMode: () -> Void

    @State private var offset = CGSize.zero

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                Image(systemName: platform.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
            }
            .overlay(
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
            )

            Text(platform.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 72, height: 86)
        .scaleEffect(offset != .zero ? 1.1 : 1.0)
        .offset(offset)
        .zIndex(offset != .zero ? 999 : 0)
        .animation(.easeInOut(duration: 0.12).repeatForever(autoreverses: true).delay(Double(index).truncatingRemainder(dividingBy: 4) * 0.04), value: isEditMode)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if offset == .zero { onEnterEditMode() }
                    offset = value.translation
                }
                .onEnded { value in
                    let rowHeight: CGFloat = 102
                    let colWidth: CGFloat = 88
                    let cols = 4
                    let currentRow = index / cols
                    let currentCol = index % cols
                    let newRow = currentRow + Int(round(value.translation.height / rowHeight))
                    let newCol = min(max(currentCol + Int(round(value.translation.width / colWidth)), 0), cols - 1)
                    let newIndex = newRow * cols + newCol
                    if newIndex >= 0, newIndex < 100, newIndex != index {
                        onMove(index, newIndex)
                    }
                    withAnimation(.spring()) { offset = .zero }
                }
        )
    }
}
