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

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .search: return "magnifyingglass"
            case .settings: return "gearshape.fill"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label(Tab.home.rawValue, systemImage: Tab.home.icon) }
                .tag(Tab.home)

            SearchView()
                .tabItem { Label(Tab.search.rawValue, systemImage: Tab.search.icon) }
                .tag(Tab.search)

            SettingsView()
                .tabItem { Label(Tab.settings.rawValue, systemImage: Tab.settings.icon) }
                .tag(Tab.settings)
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
