import SwiftUI

/// 福利首页 — 平台图标网格（类似 YBox 首页，展示全部 62 个平台入口）
struct WelfareHomeView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var searchText = ""

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private var filteredPlatforms: [WelfarePlatform] {
        if searchText.isEmpty {
            return WelfarePlatform.allPlatforms
        }
        return WelfarePlatform.allPlatforms.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 搜索栏
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("搜索平台...", text: $searchText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color(uiColor: .secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                // 平台图标网格
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(filteredPlatforms) { platform in
                            PlatformCardView(platform: platform)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .padding(.bottom, 100) // 为底栏留空间
                }
            }
            .background(backgroundColor)
            .navigationTitle("福利专区")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - 皮肤颜色

    private var backgroundColor: Color {
        settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground)
    }
}

// MARK: - 平台卡片

private struct PlatformCardView: View {
    @EnvironmentObject private var settings: AppSettings
    let platform: WelfarePlatform

    var body: some View {
        NavigationLink {
            WelfarePlatformView(platform: platform)
        } label: {
            VStack(spacing: 8) {
                // 平台图标
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(uiColor: .secondarySystemBackground))
                        .aspectRatio(1, contentMode: .fit)

                    Image(systemName: platformIcon)
                        .font(.system(size: 28))
                        .foregroundColor(accentColor)
                }

                // 平台名称
                Text(platform.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    /// 平台图标映射（后续可替换为远程 URL 图标）
    private var platformIcon: String {
        let icons: [String: String] = [
            "xvideos": "x.squareroot",
            "missav": "m.square.fill",
            "javdb": "j.square.fill",
            "91av": "9.alt.circle.fill",
            "91dsp": "d.square.fill",
            "91sp": "s.square.fill",
            "91tv": "tv.fill",
            "91pron": "p.square.fill",
            "91zpc": "z.square.fill",
            "51cg": "5.alt.circle.fill",
            "insav": "i.square.fill",
            "one": "1.circle.fill",
        ]
        return icons[platform.id] ?? "app.fill"
    }

    private var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    private var textColor: Color {
        settings.usesVisualSkin ? .white : Color(uiColor: .label)
    }
}
