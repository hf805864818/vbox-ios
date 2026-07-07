import SwiftUI

// MARK: - 豆瓣排行榜视图（基于 movie.douban.com/chart HTML 爬取）
struct DoubanRankingView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    // 所有分类榜单
    private let categories = DoubanChartService.ChartCategory.all
    @State private var selectedCategory: DoubanChartService.ChartCategory = .all[6] // 默认悬疑

    // 数据状态
    @State private var subjects: [DoubanChartService.ChartSubject] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var hasMoreData = true
    @State private var currentStart = 0
    private let pageSize = 20

    // 回调：点击条目后返回搜索关键词
    var onSelectSubject: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            headerView

            // 分类榜单横向滑动
            categoryScrollView

            // 分隔线
            Divider()
                .padding(.horizontal, 16)

            // 榜单内容
            contentView
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .task {
            await loadData(reset: true)
        }
    }

    // MARK: - 顶部标题栏
    private var headerView: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.primary)
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()

            Text("豆瓣排行榜")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.primary)

            Spacer()

            // 占位保持对称
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.clear)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
    }

    // MARK: - 分类榜单横向滑动
    private var categoryScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(categories) { category in
                    CategoryChip(
                        category: category,
                        isSelected: selectedCategory == category,
                        action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedCategory = category
                            }
                            Task {
                                await loadData(reset: true)
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
    }

    // MARK: - 内容区域
    private var contentView: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                if isLoading && subjects.isEmpty {
                    // 首次加载中
                    let columns = [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ]
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(0..<6, id: \.self) { _ in
                            ChartSkeletonRow()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                } else if let error = errorMessage {
                    // 错误提示
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 50))
                            .foregroundColor(.orange)

                        Text("加载失败")
                            .font(.system(size: 16, weight: .bold))

                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)

                        Button(action: {
                            Task { await loadData(reset: true) }
                        }) {
                            Text("重新加载")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(Color(hex: "E11D48"))
                                .cornerRadius(8)
                        }
                    }
                    .padding(.top, 80)
                } else if subjects.isEmpty {
                    // 空数据
                    VStack(spacing: 16) {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 50))
                            .foregroundColor(.gray.opacity(0.5))
                        Text("暂无数据")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    }
                    .padding(.top, 100)
                } else {
                    // 双列横排榜单
                    let columns = [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12)
                    ]
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(subjects) { subject in
                            ChartRowItem(subject: subject, settings: settings)
                                .onTapGesture {
                                    onSelectSubject?(subject.title)
                                    dismiss()
                                }
                                .onAppear {
                                    if subject.id == subjects.last?.id {
                                        Task { await loadMore() }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 20)

                    // 加载更多指示器
                    if isLoadingMore {
                        ProgressView()
                            .padding(.vertical, 16)
                    }
                }
            }
        }
    }

    // MARK: - 数据加载
    @MainActor
    private func loadData(reset: Bool) async {
        if reset {
            currentStart = 0
            subjects = []
            hasMoreData = true
            errorMessage = nil
        }

        guard !isLoading && hasMoreData else { return }

        if reset {
            isLoading = true
        } else {
            isLoadingMore = true
        }

        do {
            let newSubjects = try await DoubanChartService.shared.fetchCategoryRanking(
                category: selectedCategory,
                start: currentStart,
                count: pageSize
            )

            if reset {
                subjects = newSubjects
            } else {
                subjects.append(contentsOf: newSubjects)
            }

            hasMoreData = newSubjects.count == pageSize
            currentStart += newSubjects.count

        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        isLoadingMore = false
    }

    @MainActor
    private func loadMore() async {
        await loadData(reset: false)
    }
}

// MARK: - 分类芯片
struct CategoryChip: View {
    let category: DoubanChartService.ChartCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: category.icon)
                    .font(.system(size: 11))
                Text(category.name)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isSelected ? Color(hex: "E11D48") : Color(uiColor: .secondarySystemBackground))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 榜单行条目（双列横排：左封面、右详情，右上角标排名）
struct ChartRowItem: View {
    let subject: DoubanChartService.ChartSubject
    let settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 封面 + 排名角标
            ZStack(alignment: .topLeading) {
                if let coverURL = subject.coverURL,
                   let proxiedURL = DoubanImageProxyServer.shared.proxiedURL(for: coverURL) {
                    AsyncImage(url: proxiedURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        case .failure(_), .empty:
                            placeholderView
                        @unknown default:
                            placeholderView
                        }
                    }
                } else {
                    placeholderView
                }

                // 排名角标
                ZStack {
                    Circle()
                        .fill(rankColor)
                        .frame(width: 24, height: 24)
                    Text("\(subject.rank)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(4)
            }
            .aspectRatio(2/3, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .clipped()

            // 标题
            Text(subject.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 评分
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.yellow)
                Text(String(format: "%.1f", subject.rating))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(hex: "E11D48"))
                if let info = subject.info, !info.isEmpty {
                    Text(info)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            if let ratingCount = subject.ratingCount, !ratingCount.isEmpty {
                Text("\(ratingCount)人评价")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
        }
    }

    private var rankColor: Color {
        switch subject.rank {
        case 1: return Color(hex: "FFD700") // 金色
        case 2: return Color(hex: "C0C0C0") // 银色
        case 3: return Color(hex: "CD7F32") // 铜色
        default: return Color.black.opacity(0.6)
        }
    }

    private var placeholderView: some View {
        ZStack {
            Rectangle()
                .fill(Color.gray.opacity(0.15))
            Image(systemName: "photo")
                .font(.system(size: 20))
                .foregroundColor(.gray.opacity(0.5))
        }
    }
}

// MARK: - 骨架屏
struct ChartSkeletonRow: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.15))
                .aspectRatio(2/3, contentMode: .fill)
                .frame(maxWidth: .infinity)

            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.15))
                .frame(height: 14)

            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.15))
                .frame(width: 80, height: 12)

            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.15))
                .frame(width: 60, height: 10)
        }
        .modifier(ShimmerEffect())
    }
}

// MARK: - Shimmer 效果
private struct ShimmerEffect: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        gradient: Gradient(colors: [.clear, Color.white.opacity(0.35), .clear]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 2)
                    .offset(x: -geo.size.width + phase * geo.size.width * 2)
                    .mask(content)
                }
            )
            .onAppear {
                withAnimation(Animation.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}
