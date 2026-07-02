import SwiftUI

// MARK: - 资源列表 ViewModel
@MainActor
final class SangeListViewModel: ObservableObject {
    @Published var items: [SangeVideoItem] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var errorMsg: String?
    @Published var currentPage = 1
    @Published var hasMore = true

    let bigCategory: SangeBigCategory
    let subCategory: SangeSubCategory

    private let api = KXSPAPIService.shared
    private var hasLoaded = false

    init(bigCategory: SangeBigCategory, subCategory: SangeSubCategory) {
        self.bigCategory = bigCategory
        self.subCategory = subCategory
    }

    func loadInitial(force: Bool = false) {
        if hasLoaded && !force { return }
        hasLoaded = true
        currentPage = 1
        hasMore = true
        items.removeAll()
        loadPage(page: currentPage)
    }

    func refresh() {
        currentPage = 1
        hasMore = true
        items.removeAll()
        loadPage(page: currentPage)
    }

    func loadMoreIfNeeded(item: SangeVideoItem) {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        // 当滚动到倒数第 5 个时开始加载更多
        let threshold = max(0, items.count - 5)
        if index >= threshold {
            currentPage += 1
            loadPage(page: currentPage, append: true)
        }
    }

    private func loadPage(page: Int, append: Bool = false) {
        guard !isLoading, !isLoadingMore else { return }
        if append {
            isLoadingMore = true
        } else {
            isLoading = true
        }
        errorMsg = nil

        Task {
            do {
                let newItems: [SangeVideoItem]
                switch bigCategory.navType {
                case .video, .shortVideo:
                    newItems = try await api.fetchVideoList(classifyId: subCategory.id,
                                                            page: page,
                                                            pageSize: 20)
                default:
                    newItems = []
                }

                await MainActor.run {
                    if append {
                        self.items.append(contentsOf: newItems)
                    } else {
                        self.items = newItems
                    }
                    self.hasMore = newItems.count >= 20
                    self.isLoading = false
                    self.isLoadingMore = false
                }
            } catch {
                await MainActor.run {
                    self.errorMsg = error.localizedDescription
                    self.isLoading = false
                    self.isLoadingMore = false
                    if !append {
                        self.hasMore = false
                    }
                }
            }
        }
    }
}

// MARK: - 资源列表页面
struct SangeListView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var viewModel: SangeListViewModel

    let bigCategory: SangeBigCategory
    let subCategory: SangeSubCategory

    // 横版封面两列布局
    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    init(bigCategory: SangeBigCategory, subCategory: SangeSubCategory) {
        self.bigCategory = bigCategory
        self.subCategory = subCategory
        _viewModel = StateObject(wrappedValue: SangeListViewModel(bigCategory: bigCategory,
                                                                  subCategory: subCategory))
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoading && viewModel.items.isEmpty {
                Spacer()
                ProgressView("加载中...")
                Spacer()
            } else if let error = viewModel.errorMsg, viewModel.items.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 44))
                        .foregroundColor(.orange)
                    Text("加载失败")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(textColor)
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        viewModel.refresh()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("重新加载")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(22)
                    }
                }
                .padding(.horizontal, 32)
                Spacer()
            } else if bigCategory.navType == .comic || bigCategory.navType == .novel {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("\(bigCategory.navType.displayName)模块")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(textColor)
                    Text("暂未接入播放器")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if viewModel.items.isEmpty {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: "tray")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("暂无内容")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(textColor)
                    Text("该分类下暂无视频资源")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(viewModel.items) { item in
                            itemCell(item: item)
                                .onAppear {
                                    viewModel.loadMoreIfNeeded(item: item)
                                }
                        }

                        if viewModel.isLoadingMore {
                            VStack(spacing: 8) {
                                ProgressView()
                                Text("加载更多...")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .gridCellColumns(2)
                        } else if !viewModel.hasMore && !viewModel.items.isEmpty {
                            Text("— 已经到底啦 —")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .gridCellColumns(2)
                        }
                    }
                    .padding(12)
                }
                .refreshable {
                    viewModel.refresh()
                }
            }
        }
        .background(backgroundColor)
        .navigationTitle(subCategory.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.loadInitial() }
    }

    // MARK: 资源卡片
    @ViewBuilder
    private func itemCell(item: SangeVideoItem) -> some View {
        NavigationLink(destination: SangeVideoDetailWrapperView(item: item)) {
            videoCell(item: item)
        }
        .buttonStyle(.plain)
    }

    private func videoCell(item: SangeVideoItem) -> some View {
        // 列表接口返回的 item.cover 已经在 parseVideoList 中补全了域名
        let coverUrl = item.cover
        return VStack(alignment: .leading, spacing: 8) {
            // 封面图（横版 16:9）
            ZStack(alignment: .bottomLeading) {
                AsyncImage(url: URL(string: coverUrl)) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if phase.error != nil {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .overlay(Image(systemName: "photo").foregroundColor(.gray.opacity(0.6)))
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.15))
                            .overlay(ProgressView())
                    }
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
                )

                // 底部渐变遮罩 + 信息
                LinearGradient(gradient: Gradient(colors: [.clear, .black.opacity(0.6)]),
                               startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                HStack(spacing: 4) {
                    // 播放量
                    if let playCount = item.playCount, !playCount.isEmpty {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.9))
                        Text(formatCount(playCount))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                    }

                    Spacer()

                    // 时长
                    if let duration = item.duration, !duration.isEmpty {
                        Text(duration)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)

                // 付费标识
                if let chargeType = item.chargeType, chargeType != 0 {
                    VStack {
                        HStack {
                            Text(chargeType == 2 ? "VIP" : "付费")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    LinearGradient(colors: [Color(hex: "F59E0B"), Color(hex: "EF4444")],
                                                   startPoint: .leading, endPoint: .trailing)
                                )
                                .cornerRadius(4)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(8)
                }
            }

            // 标题
            Text(item.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            // 副标题（发布者 / 分类标签）
            HStack(spacing: 4) {
                if let publisher = item.publisherName, !publisher.isEmpty {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(publisher)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else if let remarks = item.remarks, !remarks.isEmpty {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(remarks)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
    }

    // MARK: 播放量格式化
    private func formatCount(_ count: String) -> String {
        // 如果是纯数字，做单位换算
        if let num = Double(count) {
            if num >= 10000 {
                return String(format: "%.1f万", num / 10000)
            } else if num >= 1000 {
                return String(format: "%.1fK", num / 1000)
            }
            return count
        }
        return count
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
        settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemGroupedBackground)
    }
}

// MARK: - 详情加载包装页
/// 列表页通常只返回封面等基础字段，点击后先调 /video/api/detail 拿到真实播放地址，再交给 vbox 播放器
struct SangeVideoDetailWrapperView: View {
    let item: SangeVideoItem
    @State private var vodItem: VodItem?
    @State private var errorMsg: String?
    @State private var isLoading = true
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Group {
            if let vodItem {
                VideoDetailView(video: vodItem)
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    if let errorMsg {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 44))
                            .foregroundColor(.orange)
                        Text("加载失败")
                            .font(.system(size: 16, weight: .medium))
                        Text(errorMsg)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            load()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.clockwise")
                                Text("重试")
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(22)
                        }
                    } else {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("加载播放地址...")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 32)
            }
        }
        .onAppear { load() }
    }

    private func load() {
        errorMsg = nil
        isLoading = true
        let api = KXSPAPIService.shared

        Task {
            do {
                // 优先获取详情（含完整播放地址）
                if let detail = try await api.fetchVideoDetail(id: item.id) {
                    // fetchVideoDetail 已经补全了封面和播放地址域名
                    // 合并详情数据和列表数据，取更完整的字段
                    var dict: [String: Any] = [
                        "id": detail.id,
                        "name": detail.name,
                        "cover": detail.cover.isEmpty ? api.fullImageUrl(item.cover) : detail.cover,
                        "duration": detail.duration ?? item.duration ?? "",
                        "remarks": detail.remarks ?? item.remarks ?? ""
                    ]

                    // 优先用详情的播放地址
                    let playUrl = detail.defaultPlayUrl ?? detail.playUrl ?? item.playUrl
                    if let url = playUrl, !url.isEmpty {
                        // 确保播放地址已补全域名
                        dict["playUrl"] = url.hasPrefix("http") ? url : api.fullVideoUrl(url)
                        dict["defaultPlayUrl"] = url.hasPrefix("http") ? url : api.fullVideoUrl(url)
                    }

                    // 补充详情字段
                    if let intro = detail.intro { dict["intro"] = intro }
                    if let director = detail.director { dict["director"] = director }
                    if let actors = detail.actors { dict["actors"] = actors }
                    if let year = detail.year { dict["year"] = year }
                    if let area = detail.area { dict["area"] = area }
                    if let playList = detail.playList { dict["playList"] = playList }

                    let merged = SangeVideoItem(dict: dict, navType: item.navType)
                    await MainActor.run {
                        self.vodItem = merged.toVodItem()
                        self.isLoading = false
                    }
                } else {
                    // 没有详情，用列表数据兜底
                    var dict: [String: Any] = [
                        "id": item.id,
                        "name": item.name,
                        "cover": api.fullImageUrl(item.cover),
                        "duration": item.duration ?? "",
                        "remarks": item.remarks ?? ""
                    ]
                    if let url = item.playUrl, !url.isEmpty {
                        dict["playUrl"] = api.fullVideoUrl(url)
                        dict["defaultPlayUrl"] = api.fullVideoUrl(url)
                    }
                    let merged = SangeVideoItem(dict: dict, navType: item.navType)
                    await MainActor.run {
                        self.vodItem = merged.toVodItem()
                        self.isLoading = false
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMsg = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private var accentColor: Color {
        if settings.usesLiquidSkin { return Color(hex: "38BDF8") }
        if settings.usesFrostedSkin { return Color(hex: "7C3AED") }
        return Color(hex: "E11D48")
    }
}
