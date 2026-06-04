import SwiftUI

struct ContentView: View {
    @StateObject private var settings = AppSettings()
    @State private var selectedTab: Tab = .home
    
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
                .tabItem {
                    Label(Tab.home.rawValue, systemImage: Tab.home.icon)
                }
                .tag(Tab.home)
            
            SearchView()
                .tabItem {
                    Label(Tab.search.rawValue, systemImage: Tab.search.icon)
                }
                .tag(Tab.search)
            
            SettingsView()
                .tabItem {
                    Label(Tab.settings.rawValue, systemImage: Tab.settings.icon)
                }
                .tag(Tab.settings)
        }
        .environmentObject(settings)
        .onAppear {
            // 启动时初始化蜘蛛引擎
            Task {
                await SpiderManager.shared.initialize()
            }
        }
    }
}
