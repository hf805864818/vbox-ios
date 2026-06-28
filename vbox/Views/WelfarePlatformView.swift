import SwiftUI

/// 平台二级页面 — 分类 Tab + 子分类网格 + 内容网格 + 播放器
struct WelfarePlatformView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel = WelfareViewModel()

    let platform: WelfarePlatform

    @State private var selectedGroupIndex = 0
    @State private var selectedSubcategory: WelfareSubCategory?
    @State private var selectedVideo: VodItem?

    private var currentGroup: WelfareCategoryGroup {
        platform.categoryGroups[selectedGroupIndex]
    }

    private let contentColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private let categoryColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 一级 Tab：视频 / 动漫 / 漫画 / 小说
            Picker("", selection: $selectedGroupIndex) {
                ForEach(platform.categoryGroups.indices, id: \.self) { i in
                    Label(platform.categoryGroups[i].name, systemImage: platform.categoryGroups[i].icon)
                        .tag(i)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .onChange(of: selectedGroupIndex) { _ in
                selectedSubcategory = nil
                viewModel.items = []
            }

            // 子分类网格 + 内容区域
            if let sub = selectedSubcategory {
                contentSection(subcategory: sub)
            } else {
                subcategoryGrid
            }
        }
        .background(backgroundColor)
        .navigationTitle(platform.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $selectedVideo) { video in
            VideoDetailView(video: video)
        }
    }

    // MARK: - 子分类选择网格

    private var subcategoryGrid: some View {
        ScrollView {
            LazyVGrid(columns: categoryColumns, spacing: 10) {
                ForEach(currentGroup.subcategories) { sub in
                    Button {
                        selectedSubcategory = sub
                        viewModel.loadContent(platform: platform, subcategory: sub)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: categoryIcon(for: sub.id))
                                .font(.system(size: 20))
                            Text(sub.name)
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
    }

    // MARK: - 内容展示区域

    private func contentSection(subcategory: WelfareSubCategory) -> some View {
        VStack(spacing: 0) {
            // 子分类标题栏 + 返回按钮
            HStack {
                Button {
                    selectedSubcategory = nil
                    viewModel.items = []
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(currentGroup.name)
                    }
                    .font(.system(size: 14))
                    .foregroundColor(accentColor)
                }

                Spacer()

                Text(subcategory.name)
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
                            viewModel.loadContent(platform: platform, subcategory: subcategory)
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
                                        viewModel.loadMore(platform: platform, subcategory: subcategory)
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

    private func categoryIcon(for id: String) -> String {
        let icons: [String: String] = [
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
