import SwiftUI

// MARK: - 多源发现页

struct SourceDiscoveryView: View {
    @EnvironmentObject private var settings: AppSettings

    let source: SourceDisplayItem
    let onSwitchSource: () -> Void
    let onDismiss: () -> Void

    @State private var homeData: SourceHomeData?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var selectedCategoryId: String?
    @State private var categoryVideos: [VodItem] = []
    @State private var isLoadingCategory = false

    private var displayCategories: [VodCategory] {
        homeData?.categories ?? []
    }

    private var displayVideos: [VodItem] {
        if let catId = selectedCategoryId, !categoryVideos.isEmpty {
            return categoryVideos
        }
        return homeData?.recommended ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部栏
            topBar

            if isLoading {
                Spacer()
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("正在加载 \(source.name)...")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if let error = loadError {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Button("重试") {
                        Task { await loadData() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // 分类标签（左右滑动）
                        if !displayCategories.isEmpty {
                            categoryScrollBar
                        }

                        // 内容网格
                        if displayVideos.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "tray")
                                    .font(.system(size: 36))
                                    .foregroundColor(.secondary)
                                Text("暂无推荐内容")
                                    .font(.system(size: 14))
                                    .foregroundColor(.secondary)
                                Text("可前往搜索获取更多资源")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 80)
                        } else {
                            if isLoadingCategory {
                                ProgressView()
                                    .padding(.vertical, 40)
                            }
                            videoGrid
                        }
                    }
                    .padding(.bottom, 100)
                }
            }
        }
        .background(skinBackground)
        .navigationBarHidden(true)
        .onAppear {
            if homeData == nil { Task { await loadData() } }
        }
    }

    // MARK: - 顶部栏

    private var topBar: some View {
        HStack(spacing: 10) {
            // 返回豆瓣
            Button(action: onDismiss) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            Button(action: onSwitchSource) {
                HStack(spacing: 6) {
                    Text(source.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // 源类型标签
            Text(source.category.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(categoryBadgeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(categoryBadgeColor.opacity(0.12))
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 分类滑动栏

    private var categoryScrollBar: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // 推荐（默认）
                    SourceCategoryChip(
                    name: "推荐",
                    isSelected: selectedCategoryId == nil
                )
                    .onTapGesture {
                        selectedCategoryId = nil
                        categoryVideos = []
                    }

                    ForEach(displayCategories) { cat in
                        SourceCategoryChip(
                            name: cat.typeName,
                            isSelected: selectedCategoryId == cat.typeId
                        )
                        .onTapGesture {
                            if selectedCategoryId != cat.typeId {
                                selectedCategoryId = cat.typeId
                                Task { await loadCategoryContent(cat) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            Divider()
                .padding(.horizontal, 16)
        }
    }

    // MARK: - 视频网格

    private var videoGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            spacing: 16
        ) {
            ForEach(displayVideos) { video in
                NavigationLink(destination: VideoDetailView(video: video, searchKeyword: video.vodName)) {
                    SourceVideoCard(
                    video: video,
                    referer: source.referer,
                    settings: settings
                )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - 皮肤

    private var skinBackground: some View {
        Group {
            if settings.skinMode == .liquid {
                LinearGradient(
                    colors: [Color(hex: "1a1a2e"), Color(hex: "16213e"), Color(hex: "0f3460")],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            } else {
                Color(uiColor: .systemBackground).ignoresSafeArea()
            }
        }
    }

    private var categoryBadgeColor: Color {
        switch source.category {
        case .cloudCMS, .cloudSPA: return Color(hex: "007AFF")
        case .cloudForum: return Color(hex: "FF9500")
        case .api: return Color(hex: "34C759")
        case .jsSpider: return Color(hex: "AF52DE")
        case .zhanyuan: return Color(hex: "FF3B30")
        }
    }

    // MARK: - 数据加载

    private func loadData() async {
        isLoading = true
        loadError = nil
        if let data = await SpiderManager.shared.fetchHomeData(for: source) {
            homeData = data
        } else {
            loadError = "\(source.name) 暂无数据，请检查网络或切换其他源"
        }
        isLoading = false
    }

    private func loadCategoryContent(_ cat: VodCategory) async {
        isLoadingCategory = true
        let items = await SpiderManager.shared.fetchCategoryContent(
            categoryTypeId: cat.typeId, page: 1
        )
        categoryVideos = items
        isLoadingCategory = false
    }
}

// MARK: - 分类标签

private struct SourceCategoryChip: View {
    let name: String
    let isSelected: Bool

    var body: some View {
        Text(name)
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected ? Color(hex: "E11B48") : Color(uiColor: .systemGray6))
            )
    }
}

// MARK: - 视频卡片

private struct SourceVideoCard: View {
    let video: VodItem
    let referer: String?
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 封面图
            ZStack(alignment: .bottomTrailing) {
                PlatformAsyncImage.sourceCover(video.vodPic, referer: referer)
                    .aspectRatio(2/3, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .cornerRadius(8)

                // 备注标签
                if let remarks = video.vodRemarks, !remarks.isEmpty {
                    Text(remarks)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.65))
                        .cornerRadius(4)
                        .padding(4)
                }
            }

            // 标题
            Text(video.vodName)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(settings.skinMode == .liquid ? .white : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            // 年份/地区
            if let year = video.vodYear, !year.isEmpty {
                Text(year)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
}