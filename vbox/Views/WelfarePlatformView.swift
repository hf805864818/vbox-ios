import SwiftUI

/// 平台二级页面 — 横向 Tab 栏 + 分区网格 + 内容网格 + 播放器
struct WelfarePlatformView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel = WelfareViewModel()

    let platform: WelfarePlatform

    @State private var selectedPageIndex = 0
    @State private var selectedSection: WelfareSection?
    @State private var selectedVideo: VodItem?

    private var currentPage: WelfarePage {
        platform.pages.isEmpty
            ? WelfarePage(id: "_empty", name: "首页", icon: "house.fill", sections: [])
            : platform.pages[selectedPageIndex]
    }

    private let contentColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private let sectionColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 横向可滚动页面 Tab 栏
            pageTabBar

            // 分区网格 或 内容区域
            if let section = selectedSection {
                contentSection(section: section)
            } else {
                sectionGrid
            }
        }
        .background(backgroundColor)
        .navigationTitle(platform.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedVideo) { video in
            VideoDetailView(video: video)
        }
    }

    // MARK: - 横向页面 Tab 栏

    private var pageTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(platform.pages.indices, id: \.self) { i in
                    Button {
                        selectedPageIndex = i
                        selectedSection = nil
                        viewModel.items = []
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: platform.pages[i].icon)
                                .font(.system(size: 12))
                            Text(platform.pages[i].name)
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(selectedPageIndex == i ? accentColor : Color.clear)
                        .foregroundColor(selectedPageIndex == i ? .white : textColor)
                        .cornerRadius(20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(accentColor.opacity(0.4), lineWidth: selectedPageIndex == i ? 0 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(backgroundColor)
    }

    // MARK: - 分区选择网格

    private var sectionGrid: some View {
        let sections = currentPage.sections

        if sections.isEmpty {
            // 无分区时直接显示该页面对应的内容
            return AnyView(
                contentSection(section: WelfareSection(id: currentPage.id, name: currentPage.name, keyword: ""))
                    .onAppear {
                        selectedSection = WelfareSection(id: currentPage.id, name: currentPage.name, keyword: "")
                        viewModel.loadContent(platform: platform, section: selectedSection!)
                    }
            )
        }

        return AnyView(
            ScrollView {
                LazyVGrid(columns: sectionColumns, spacing: 10) {
                    ForEach(sections) { section in
                        Button {
                            selectedSection = section
                            viewModel.loadContent(platform: platform, section: section)
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: sectionIcon(for: section.id))
                                    .font(.system(size: 20))
                                Text(section.name)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(accentColor)
                            .frame(maxWidth: .infinity)
                            .frame(height: 72)
                            .background(accentColor.opacity(0.1))
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 100)
            }
        )
    }

    // MARK: - 内容展示区域

    private func contentSection(section: WelfareSection) -> some View {
        VStack(spacing: 0) {
            // 标题栏 + 返回按钮
            HStack {
                Button {
                    selectedSection = nil
                    viewModel.items = []
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(currentPage.name)
                    }
                    .font(.system(size: 14))
                    .foregroundColor(accentColor)
                }

                Spacer()

                Text(section.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(textColor)

                Spacer()

                // 占位保持居中
                Color.clear.frame(width: 60)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().padding(.horizontal, 16)

            // 内容网格
            ScrollView {
                if viewModel.isLoading && viewModel.items.isEmpty {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("加载中...")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text(error)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") {
                            viewModel.loadContent(platform: platform, section: section)
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: contentColumns, spacing: 14) {
                        ForEach(viewModel.items) { item in
                            VodCardView(item: item)
                                .onTapGesture {
                                    selectedVideo = item
                                }
                                .onAppear {
                                    if item.vodId == viewModel.items.last?.vodId {
                                        viewModel.loadMore(platform: platform, section: section)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .padding(.bottom, 100)

                    if viewModel.isLoading && !viewModel.items.isEmpty {
                        ProgressView()
                            .padding()
                    }
                }
            }
        }
    }

    // MARK: - 辅助方法

    private func sectionIcon(for id: String) -> String {
        let icons: [String: String] = [
            "recommend": "star.fill",
            "latest": "clock.fill",
            "hot": "flame.fill",
            "all": "square.grid.2x2.fill",
            "jingxuan": "star.fill",
            "zuixin": "clock.fill",
            "xuejiao": "person.fill",
            "guochan": "flag.fill",
            "fuliji": "gift.fill",
            "erciyuan": "sparkles",
            "wanghuang": "flame.fill",
            "luanlun": "arrow.triangle.swap",
            "zhongkou": "exclamationmark.triangle.fill",
            "av": "film.fill",
            "yiyu": "globe",
            "chuanmei": "play.tv.fill",
            "zongyi": "music.note.tv.fill",
        ]
        return icons[id] ?? "square.grid.2x2.fill"
    }

    private var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }

    private var textColor: Color {
        settings.usesVisualSkin ? .white : Color(uiColor: .label)
    }

    private var backgroundColor: Color {
        settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground)
    }
}

// MARK: - 视频封面卡片

private struct VodCardView: View {
    @EnvironmentObject private var settings: AppSettings
    let item: VodItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 封面图
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .aspectRatio(2/3, contentMode: .fit)

                if let url = URL(string: item.vodPic) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(2/3, contentMode: .fill)
                                .clipped()
                        case .failure, .empty:
                            Image(systemName: "photo")
                                .font(.system(size: 24))
                                .foregroundColor(.secondary)
                        @unknown default:
                            EmptyView()
                        }
                    }
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary)
                }
            }
            .cornerRadius(8)
            .clipped()

            // 标题
            Text(item.vodName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(textColor)
                .lineLimit(2)

            // 来源备注
            if let remarks = item.vodRemarks, !remarks.isEmpty {
                Text(remarks)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var textColor: Color {
        settings.usesVisualSkin ? .white : Color(uiColor: .label)
    }
}
