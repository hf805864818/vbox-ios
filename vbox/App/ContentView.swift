import SwiftUI

struct ContentView: View {
    @StateObject private var settings = AppSettings()
    @State private var selectedTab: Tab = .home
    @State private var showUpdateAlert = false
    @State private var showUpdateSheet = false

    enum Tab: String, CaseIterable {
        case home = "首页"
        case search = "搜索"
        case settings = "设置"

        // 未选中空心图标
        var iconOutline: String {
            switch self {
            case .home: return "house"
            case .search: return "magnifyingglass"
            case .settings: return "gearshape"
            }
        }
        
        // 选中实心图标
        var iconFill: String {
            switch self {
            case .home: return "house.fill"
            case .search: return "magnifyingglass.circle.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    var body: some View {
        ZStack {
            if settings.usesLiquidSkin {
                AppLiquidBackground()
                    .ignoresSafeArea()
            } else if settings.usesFrostedSkin {
                AppFrostedBackground()
                    .ignoresSafeArea()
            } else {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
            }

            ZStack(alignment: .bottom) {
                // 页面内容区域，全屏无遮挡
                Group {
                    switch selectedTab {
                    case .home: HomeView()
                    case .search: SearchView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
                .ignoresSafeArea(.keyboard, edges: .bottom)

                // 悬浮式底部导航栏
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Tab.allCases, id: \.self) { tab in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedTab = tab
                                }
                            } label: {
                                VStack(spacing: 1) {
                                    Image(systemName: selectedTab == tab ? tab.iconFill : tab.iconOutline)
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(selectedTab == tab ? activeTabColor : inactiveTabColor)

                                    Text(tab.rawValue)
                                        .font(.system(size: 10, weight: selectedTab == tab ? .semibold : .regular))
                                        .foregroundColor(selectedTab == tab ? activeTabColor : inactiveTabColor)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .frame(maxWidth: min(UIScreen.main.bounds.width - 120, 300))
                    .background(
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .background(Capsule().fill(tabBarBaseColor))
                            .overlay(
                                Capsule()
                                    .stroke(tabBarStrokeColor, lineWidth: 1)
                            )
                    )
                    .clipShape(Capsule())
                    .padding(.bottom, 8)
                }
            }
        }
        .environmentObject(settings)
        .preferredColorScheme(settings.preferredColorScheme)
        .tint(activeTabColor)
        .onChange(of: settings.searchRequestId) { _ in
            if !settings.searchQuery.isEmpty { selectedTab = .search }
        }
        .onAppear {
            Task {
                await SpiderManager.shared.initialize()
                await UpdateManager.shared.checkForUpdate()
                if UpdateManager.shared.hasUpdate { showUpdateAlert = true }
            }
        }
        .alert("发现新版本", isPresented: $showUpdateAlert) {
            Button("稍后") { }
            Button("查看更新") { showUpdateSheet = true }
        } message: {
            if !UpdateManager.shared.releaseNotes.isEmpty {
                Text(UpdateManager.shared.releaseNotes)
            } else {
                Text("新版本 v\(UpdateManager.shared.latestVersion) 可用")
            }
        }
        .sheet(isPresented: $showUpdateSheet) { UpdateSheet() }
    }

    private var activeTabColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    private var inactiveTabColor: Color {
        if settings.usesLiquidSkin { return Color.white.opacity(0.72) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondaryLabel) }
        return Color(uiColor: .systemGray2)
    }

    private var tabBarBaseColor: Color {
        if settings.usesLiquidSkin { return Color.black.opacity(0.34) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondarySystemBackground).opacity(0.62) }
        return Color(uiColor: .systemBackground).opacity(0.9)
    }

    private var tabBarStrokeColor: Color {
        if settings.usesLiquidSkin { return Color.white.opacity(0.22) }
        if settings.usesFrostedSkin { return Color.white.opacity(0.34) }
        return Color(uiColor: .systemGray4)
    }
}

struct AppLiquidBackground: View {
    @State private var phase = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: "050816"),
                    Color(hex: "111827"),
                    Color(hex: "1E1B4B")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color(hex: "22D3EE").opacity(0.34))
                .frame(width: 320, height: 320)
                .blur(radius: 70)
                .offset(x: phase ? 130 : -120, y: phase ? -240 : -160)

            Circle()
                .fill(Color(hex: "A855F7").opacity(0.42))
                .frame(width: 360, height: 360)
                .blur(radius: 80)
                .offset(x: phase ? -150 : 140, y: phase ? 120 : 260)

            Circle()
                .fill(Color(hex: "F43F5E").opacity(0.24))
                .frame(width: 260, height: 260)
                .blur(radius: 70)
                .offset(x: phase ? 90 : -80, y: phase ? 320 : 140)
        }
        .animation(.easeInOut(duration: 7).repeatForever(autoreverses: true), value: phase)
        .onAppear { phase = true }
    }
}

struct AppFrostedBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground),
                    Color(hex: "EEF2FF").opacity(0.55),
                    Color(hex: "FDF2F8").opacity(0.45)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color(hex: "60A5FA").opacity(0.22))
                .frame(width: 280, height: 280)
                .blur(radius: 74)
                .offset(x: -120, y: -190)

            Circle()
                .fill(Color(hex: "C084FC").opacity(0.18))
                .frame(width: 320, height: 320)
                .blur(radius: 86)
                .offset(x: 150, y: 220)

            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.72)
        }
    }
}
