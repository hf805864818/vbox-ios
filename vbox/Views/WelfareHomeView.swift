import SwiftUI

// MARK: - 福利首页（视频/直播/漫画 三大分类）
struct WelfareHomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var ybox = YBoxService2.shared

    var body: some View {
        NavigationView {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    // 标题
                    VStack(spacing: 4) {
                        Text("福利专区")
                            .font(.system(size: 28, weight: .bold))
                        Text("视频 · 直播 · 漫画")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 16)

                    // 三大分类区块
                    ForEach(ybox.categories) { category in
                        WelfareCategorySection(category: category)
                    }
                }
                .padding(.bottom, 30)
            }
            .background(backgroundColor)
            .navigationBarHidden(true)
        }
    }

    private var backgroundColor: Color {
        settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemGroupedBackground)
    }
}

// MARK: - 分类区块
struct WelfareCategorySection: View {
    let category: YBoxCategory2
    @EnvironmentObject private var settings: AppSettings

    private var iconName: String {
        switch category.name {
        case "视频": return "play.rectangle.fill"
        case "直播": return "antenna.radiowaves.left.and.right"
        case "漫画": return "book.fill"
        default: return "square.grid.3x3"
        }
    }

    private var gradientColors: [Color] {
        switch category.name {
        case "视频": return [Color(hex: "E11D48"), Color(hex: "F43F5E")]
        case "直播": return [Color(hex: "7C3AED"), Color(hex: "A855F7")]
        case "漫画": return [Color(hex: "059669"), Color(hex: "34D399")]
        default: return [Color(hex: "E11D48"), Color(hex: "7C3AED")]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 分类标题
            HStack {
                LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing)
                    .mask(
                        HStack(spacing: 6) {
                            Image(systemName: iconName)
                                .font(.system(size: 18, weight: .semibold))
                            Text(category.name)
                                .font(.system(size: 20, weight: .bold))
                        }
                    )
                    .frame(height: 28)
                Spacer()
            }
            .padding(.horizontal, 20)

            // 平台网格（每行3个）
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(category.platforms) { platform in
                    NavigationLink(destination: platformDestination(platform)) {
                        WelfarePlatformCard2(platform: platform, colors: gradientColors)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func platformDestination(_ platform: YBoxPlatform2) -> some View {
        // 优先：有爬虫配置的平台，统一走 YBoxCrawlerContentView → WelfarePlatformView
        if let pid = platform.crawlerPlatformId, !pid.isEmpty {
            YBoxCrawlerContentView(platform: platform)
        }
        // "更多直播"/"更多漫画" 折叠入口
        else if platform.name == "更多直播" {
            YBoxLiveSourceListView()
        }
        else if platform.name == "更多漫画" {
            YBoxComicListView()
        }
        // YBox 自有平台：香蕉秀系列
        else if platform.baseURL.contains("zfvwi8") {
            YBoxBananaListView(platform: platform)
        }
        // YBox 自有平台：1080视频
        else if platform.baseURL.contains("1080") {
            YBoxCrawlerContentView(platform: platform)
        }
        // 其他自有平台
        else {
            switch platform.type {
            case .video:
                YBoxBananaListView(platform: platform)
            case .live:
                YBoxLiveSourceListView()
            case .comic:
                YBoxComicListView()
            case .audio:
                YBoxWebSourceListView(platform: platform)
            }
        }
    }
}

// MARK: - 平台卡片
struct WelfarePlatformCard2: View {
    let platform: YBoxPlatform2
    let colors: [Color]

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: colors.map { $0.opacity(0.15) },
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 72)
                VStack(spacing: 4) {
                    Image(systemName: platform.icon)
                        .font(.system(size: 24))
                        .foregroundColor(colors[0])
                    Text(platform.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
            }
            Text(platform.desc)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}
