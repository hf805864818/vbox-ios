import SwiftUI

// MARK: - 福利首页（仅保留 MissAV 和 香蕉秀）
struct WelfareHomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var ybox = YBoxService2.shared
    @State private var selectedTab: WelfareTab = .video

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
                // 顶部导航栏（仅保留设置图标，无跳转）
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("福利")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(settings.usesVisualSkin ? .white : .primary)
                    }
                    Spacer()
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 16))
                        .foregroundColor(settings.usesVisualSkin ? .white.opacity(0.8) : .secondary)
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
                            }
                        }) {
                            VStack(spacing: 6) {
                                HStack(spacing: 6) {
                                    Image(systemName: tab.icon)
                                        .font(.system(size: 14))
                                    Text(tab.rawValue)
                                        .font(.system(size: 15, weight: selectedTab == tab ? .bold : .regular))
                                }
                                .foregroundColor(selectedTab == tab ?
                                    (settings.usesVisualSkin ? .white : .white) :
                                    (settings.usesVisualSkin ? .white.opacity(0.6) : .white.opacity(0.45))
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
                .padding(.bottom, 8)

                // 内容区域
                TabView(selection: $selectedTab) {
                    platformGrid(for: .video).tag(WelfareTab.video)
                    platformGrid(for: .live).tag(WelfareTab.live)
                    platformGrid(for: .comic).tag(WelfareTab.comic)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationBarHidden(true)
        }
    }

    // MARK: - 平台网格（仅保留 MissAV 和 香蕉秀）
    private func platformGrid(for tab: WelfareTab) -> some View {
        let platforms = filteredPlatforms(for: tab)

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
                    ForEach(platforms) { platform in
                        NavigationLink(destination: destinationView(for: platform)) {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(colors: platformGradient(platform.name), startPoint: .topLeading, endPoint: .bottomTrailing))
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
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 100)
            }
        }
    }

    /// 仅保留 MissAV 和 香蕉秀 路由
    private func destinationView(for platform: YBoxPlatform2) -> some View {
        if platform.name == "MissAV" {
            return AnyView(MissAVHomeView().environmentObject(settings))
        } else {
            // 香蕉秀/幻想次元/午夜寻欢/绿帽淫妻 都走香蕉秀API视图
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
        // 仅保留 MissAV 和 香蕉秀系列
        return all.filter { $0.name == "MissAV" || $0.name == "香蕉秀"
            || $0.name == "幻想次元" || $0.name == "午夜寻欢"
            || $0.name == "绿帽淫妻" || $0.name == "1080视频"
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
            "幻想次元":      [Color(hex: "A29BFE"), Color(hex: "6C5CE7")],
            "午夜寻欢":      [Color(hex: "FDCB6E"), Color(hex: "E17055")],
            "绿帽淫妻":      [Color(hex: "00B894"), Color(hex: "00CEC9")],
            "1080视频":      [Color(hex: "0984E3"), Color(hex: "74B9FF")],
        ]
        return colorMap[name, default: [Color(hex: "636E72"), Color(hex: "B2BEC3")]]
    }
}
