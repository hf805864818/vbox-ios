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

    init(bigCategory: SangeBigCategory, subCategory: SangeSubCategory) {
        self.bigCategory = bigCategory
        self.subCategory = subCategory
    }

    func loadInitial() {
        currentPage = 1
        hasMore = true
        items.removeAll()
        loadPage(page: currentPage)
    }

    func loadMoreIfNeeded(item: SangeVideoItem) {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        if item.id == items.last?.id {
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
                    self.hasMore = false
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

    private let columns = [
        GridItem(.flexible(), spacing: 10),
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
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundColor(.orange)
                    Text(error).foregroundColor(.secondary).multilineTextAlignment(.center)
                    Button("重试") { viewModel.loadInitial() }
                }
                .padding(.horizontal, 32)
                Spacer()
            } else if bigCategory.navType == .comic || bigCategory.navType == .novel {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 44)).foregroundColor(.secondary)
                    Text("\(bigCategory.navType.displayName)模块暂未接入播放器")
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(viewModel.items) { item in
                            itemCell(item: item)
                                .onAppear {
                                    viewModel.loadMoreIfNeeded(item: item)
                                }
                        }

                        if viewModel.isLoadingMore {
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 50)
                        }
                    }
                    .padding(12)
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
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: URL(string: item.cover)) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .overlay(Image(systemName: "photo").foregroundColor(.gray))
                    }
                }
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if let duration = item.duration, !duration.isEmpty {
                    Text(duration)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                        .padding(6)
                }
            }

            Text(item.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(textColor)
                .lineLimit(2)

            if let remarks = item.remarks, !remarks.isEmpty {
                Text(remarks)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
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
/// 列表页通常只返回封面等基础字段，点击后先调 /video/api/video/detail 拿到真实播放地址，再交给 vbox 播放器
struct SangeVideoDetailWrapperView: View {
    let item: SangeVideoItem
    @State private var vodItem: VodItem?
    @State private var errorMsg: String?

    var body: some View {
        Group {
            if let vodItem {
                VideoDetailView(video: vodItem)
            } else {
                VStack(spacing: 16) {
                    Spacer()
                    if let errorMsg {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 40)).foregroundColor(.orange)
                        Text(errorMsg).foregroundColor(.secondary).multilineTextAlignment(.center)
                        Button("重试") { load() }
                    } else {
                        ProgressView("加载播放地址...")
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
        Task {
            do {
                if let detail = try await KXSPAPIService.shared.fetchVideoDetail(id: item.id) {
                    var dict: [String: Any] = [
                        "id": detail.id,
                        "name": detail.name,
                        "cover": detail.cover.isEmpty ? item.cover : detail.cover,
                        "duration": detail.duration ?? item.duration ?? "",
                        "remarks": detail.remarks ?? item.remarks ?? ""
                    ]
                    if let url = detail.playUrl, !url.isEmpty {
                        dict["playUrl"] = url
                    } else if let url = item.playUrl, !url.isEmpty {
                        dict["playUrl"] = url
                    }
                    let merged = SangeVideoItem(dict: dict, navType: item.navType)
                    await MainActor.run {
                        self.vodItem = merged.toVodItem()
                    }
                } else {
                    await MainActor.run {
                        self.vodItem = item.toVodItem()
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMsg = error.localizedDescription
                }
            }
        }
    }
}
