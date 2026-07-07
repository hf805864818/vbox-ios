import SwiftUI

// MARK: - 福利首页（视频/直播/漫画 Tab切换 + 4列App图标 + 长按排序）

struct WelfareHomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var ybox = YBoxService2.shared
    @State private var selectedTab: WelfareTab = .video
    @State private var isEditMode = false
    @State private var platformOrder: [String: [String]] = [:] // 缓存排序

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
                        Text("长按拖动可排序")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.6))
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
            .background(backgroundColor)
            .navigationBarHidden(true)
            .onAppear { loadOrder() }
        }
    }

    // MARK: - 平台网格（4列App图标风格）

    private func platformGrid(for tab: WelfareTab) -> some View {
        let platforms = filteredPlatforms(for: tab)
        let ordered = applyOrder(platforms, for: tab)

        return ScrollView(showsIndicators: false) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4),
                spacing: 16
            ) {
                ForEach(ordered) { platform in
                    NavigationLink(destination: platformDestination(platform)) {
                        PlatformIconCard(
                            platform: platform,
                            isEditMode: isEditMode,
                            gradient: platformGradient(platform.name)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 100)
        }
    }

    // MARK: - 平台入口图标卡片（App图标风格）

    struct PlatformIconCard: View {
        let platform: YBoxPlatform2
        let isEditMode: Bool
        let gradient: [Color]
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
                    Group {
                        if isEditMode {
                            Circle()
                                .stroke(Color.white.opacity(0.3), lineWidth: 2)
                        }
                    }
                )

                Text(platform.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 72, height: 86)
            .offset(isEditMode ? CGSize(width: 0, height: -3) : .zero)
            .animation(
                isEditMode ?
                Animation.easeInOut(duration: 0.12).repeatForever(autoreverses: true).delay(Double.random(in: 0...0.15))
                : .default,
                value: isEditMode
            )
            .gesture(isEditMode ? dragGesture : nil)
        }

        private var dragGesture: some Gesture {
            DragGesture()
                .onChanged { value in
                    offset = value.translation
                }
                .onEnded { _ in
                    withAnimation(.spring()) { offset = .zero }
                }
        }
    }

    // MARK: - 平台列表过滤 + 排序

    private func filteredPlatforms(for tab: WelfareTab) -> [YBoxPlatform2] {
        let typeMap: [WelfareTab: YBoxPlatform2.PlatformType2] = [
            .video: .video,
            .live: .live,
            .comic: .comic
        ]
        guard let pt = typeMap[tab] else { return [] }

        // 收集 24个Python平台 + MissAV
        let all: [YBoxPlatform2] = {
            let cats = ybox.categories
            for c in cats {
                if c.name == tab.rawValue { return c.platforms }
            }
            return []
        }()
        return all.filter { $0.type == pt || pt == .video }
    }

    private func applyOrder(_ platforms: [YBoxPlatform2], for tab: WelfareTab) -> [YBoxPlatform2] {
        let saved = platformOrder[tab.rawValue] ?? []
        if saved.isEmpty { return platforms }
        return platforms.sorted { a, b in
            let ai = saved.firstIndex(of: a.id) ?? Int.max
            let bi = saved.firstIndex(of: b.id) ?? Int.max
            return ai < bi
        }
    }

    private func loadOrder() {
        if let data = UserDefaults.standard.data(forKey: "welfare_platform_order"),
           let dict = try? JSONDecoder().decode([String: [String]].self, from: data) {
            platformOrder = dict
        }
    }

    private func saveOrder() {
        if let data = try? JSONEncoder().encode(platformOrder) {
            UserDefaults.standard.set(data, forKey: "welfare_platform_order")
        }
    }

    // MARK: - 目的地路由

    @ViewBuilder
    private func platformDestination(_ platform: YBoxPlatform2) -> some View {
        switch platform.name {
        case "MissAV":
            MissAVHomeView()
        case "香蕉秀":
            YBoxXjspMainView(platform: platform)
        case "色播聚合":
            YBoxLiveSourceListView()
        case "Pandalive":
            YBoxLiveSourceListView()
        default:
            if let pid = platform.crawlerPlatformId, !pid.isEmpty {
                YBoxCrawlerContentView(platform: platform)
            } else {
                YBoxPlatformDetailView(platform: platform)
            }
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

    private var backgroundColor: some View {
        Color(uiColor: .systemBackground).ignoresSafeArea()
    }
}

// MARK: - 占位详情页（未对接的Python平台）

struct YBoxPlatformDetailView: View {
    let platform: YBoxPlatform2
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 16) {
                // 平台信息头部
                VStack(spacing: 12) {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(hex: "E11D48"), Color(hex: "F43F5E")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 72, height: 72)
                        .overlay(
                            Image(systemName: platform.icon)
                                .font(.system(size: 32))
                                .foregroundColor(.white)
                        )

                    Text(platform.name)
                        .font(.system(size: 22, weight: .bold))

                    Text(platform.desc)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .padding(.top, 40)

                // 占位提示
                VStack(spacing: 8) {
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.yellow)
                    Text("对接开发中")
                        .font(.system(size: 16, weight: .semibold))
                    Text("该平台正在按优先级逐步对接\n请稍候")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 40)

                // 分类预览（模拟）
                VStack(alignment: .leading, spacing: 12) {
                    Text("分类预览")
                        .font(.system(size: 16, weight: .bold))
                        .padding(.horizontal, 20)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) {
                        ForEach(0..<6, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                                .frame(height: 88)
                                .overlay(
                                    Text("分类 \(i+1)")
                                        .font(.system(size: 14))
                                        .foregroundColor(.secondary)
                                )
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 20)
            }
            .padding(.bottom, 40)
        }
        .navigationTitle(platform.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 爬虫内容视图（通用平台浏览页）

struct YBoxCrawlerContentView: View {
    let platform: YBoxPlatform2
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        WelfarePlatformView(
            platform: WelfarePlatform.adaptive(
                id: platform.crawlerPlatformId ?? platform.name,
                name: platform.name,
                searchPrefix: platform.name
            )
        )
    }
}
