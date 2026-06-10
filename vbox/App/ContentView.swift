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
                            VStack(spacing: 4) {
                                Image(systemName: selectedTab == tab ? tab.iconFill : tab.iconOutline)
                                    .font(.system(size: 20))
                                    .foregroundColor(selectedTab == tab ? .accentColor : Color(uiColor: .systemGray2))
                                
                                Text(tab.rawValue)
                                    .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                                    .foregroundColor(selectedTab == tab ? .accentColor : Color(uiColor: .systemGray2))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(selectedTab == tab ? Color.accentColor.opacity(0.15) : .clear)
                            )
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 26)
                        .fill(Color(uiColor: .systemBackground))
                        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .environmentObject(settings)
        .onChange(of: settings.searchQuery) { newVal in
            if !newVal.isEmpty { selectedTab = .search }
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
}
