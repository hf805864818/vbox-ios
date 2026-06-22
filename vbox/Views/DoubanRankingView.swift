import SwiftUI

// MARK: - 豆瓣排行榜视图
struct DoubanRankingView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    // 所有排行榜类型
    private let rankingTypes = DoubanService.RankingType.allCases
    @State private var selectedType: DoubanService.RankingType = .movieWeekly

    // 数据状态
    @State private var subjectsMap: [DoubanService.RankingType: [DoubanSubject]] = [:]
    @State private var isLoadingMap: [DoubanService.RankingType: Bool] = [:]
    @State private var hasMoreMap: [DoubanService.RankingType: Bool] = [:]
    @State private var pageMap: [DoubanService.RankingType: Int] = [:]
    private let pageSize = 20

    // 回调：点击条目后返回搜索关键词
    var onSelectSubject: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            headerView

            // 分类榜单横向滑动
            typeScrollView

            // 分隔线
            Divider()
                .padding(.horizontal, 16)

            // 榜单内容
            contentView
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .task {
            await loadData(for: selectedType, reset: true)
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
    private var typeScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(rankingTypes) { type in
                    TypeChip(
                        type: type,
                        isSelected: selectedType == type,
                        action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedType = type
                            }
                            Task {
                                await loadData(for: type, reset: true)
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
                if isLoading(for: selectedType) && subjects(for: selectedType).isEmpty {
                    // 首次加载中
                    ForEach(0..<6, id: \.self) { _ in
                        RankingSkeletonRow()
                    }
                    .padding(.top, 12)
                } else if subjects(for: selectedType).isEmpty {
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
                    // 榜单列表
                    let subjects = subjects(for: selectedType)
                    LazyVStack(spacing: 12) {
                        ForEach(Array(subjects.enumerated()), id: \.element.id) { index, subject in
                            RankingRowItem(
                                rank: index + 1,
                                subject: subject,
                                settings: settings
                            )
                            .onTapGesture {
                                onSelectSubject?(subject.title)
                                dismiss()
                            }
                            .onAppear {
                                // 接近底部加载更多
                                if index >= subjects.count - 5 {
                                    Task {
                                        await loadMore(for: selectedType)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 20)

                    // 加载更多指示器
                    if isLoading(for: selectedType) && !subjects.isEmpty {
                        ProgressView()
                            .padding(.vertical, 16)
                    }
                }
            }
        }
    }

    // MARK: - 数据操作
    private func subjects(for type: DoubanService.RankingType) -> [DoubanSubject] {
        subjectsMap[type] ?? []
    }

    private func isLoading(for type: DoubanService.RankingType) -> Bool {
        isLoadingMap[type] ?? false
    }

    private func hasMore(for type: DoubanService.RankingType) -> Bool {
        hasMoreMap[type] ?? true
    }

    private func page(for type: DoubanService.RankingType) -> Int {
        pageMap[type] ?? 0
    }

    @MainActor
    private func loadData(for type: DoubanService.RankingType, reset: Bool) async {
        if reset {
            subjectsMap[type] = []
            pageMap[type] = 0
            hasMoreMap[type] = true
        }

        guard !isLoading(for: type) && hasMore(for: type) else { return }

        isLoadingMap[type] = true

        do {
            let start = page(for: type) * pageSize
            let newSubjects = try await DoubanService.shared.fetchRanking(type, start: start, count: pageSize)

            var current = subjects(for: type)
            if reset {
                current = newSubjects
            } else {
                current.append(contentsOf: newSubjects)
            }
            subjectsMap[type] = current
            hasMoreMap[type] = newSubjects.count == pageSize
            pageMap[type] = page(for: type) + 1
        } catch {
            print("[DoubanRanking] 加载失败 \(type.displayName): \(error)")
        }

        isLoadingMap[type] = false
    }

    @MainActor
    private func loadMore(for type: DoubanService.RankingType) async {
        await loadData(for: type, reset: false)
    }
}

// MARK: - 分类芯片
struct TypeChip: View {
    let type: DoubanService.RankingType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: type.icon)
                    .font(.system(size: 12))
                Text(type.displayName)
                    .font(.system(size: 13, weight: isSelected ? .bold : .medium))
            }
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? Color(hex: "E11D48") : Color(uiColor: .secondarySystemBackground))
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - 榜单行条目（双列横排：左封面、右详情，右上角标排名）
struct RankingRowItem: View {
    let rank: Int
    let subject: DoubanSubject
    let settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            // 左侧封面
            ZStack(alignment: .topTrailing) {
                if let urlString = subject.coverImageURL,
                   let url = DoubanImageProxyServer.shared.proxiedURL(for: urlString) {
                    AsyncImage(url: url) { phase in
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
                        .frame(width: 28, height: 28)
                    Text("\(rank)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
                .offset(x: 6, y: -6)
            }
            .frame(width: 90, height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // 右侧详情
            VStack(alignment: .leading, spacing: 6) {
                Text(subject.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(2)

                if let year = subject.year, !year.isEmpty {
                    Text(year)
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }

                if let genres = subject.genres, !genres.isEmpty {
                    Text(genres.joined(separator: " / "))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if let subtitle = subject.card_subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .lineLimit(2)
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.yellow)
                    Text(String(format: "%.1f", subject.ratingValue))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(hex: "E11D48"))
                    if let count = subject.rating?.count, count > 0 {
                        Text("(\(count)人评价)")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(.vertical, 4)

            Spacer()
        }
        .frame(height: 130)
        .padding(.vertical, 6)
    }

    private var rankColor: Color {
        switch rank {
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
                .font(.system(size: 24))
                .foregroundColor(.gray.opacity(0.5))
        }
    }
}

// MARK: - 骨架屏
struct RankingSkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.15))
                .frame(width: 90, height: 130)

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 150, height: 16)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 80, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 120, height: 12)
                Spacer()
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 60, height: 14)
            }
            .padding(.vertical, 4)

            Spacer()
        }
        .frame(height: 130)
        .padding(.vertical, 6)
        .shimmering()
    }
}

// MARK: -  shimmer 效果扩展
private struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(
                        gradient: Gradient(colors: [.clear, Color.white.opacity(0.3), .clear]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 2)
                    .offset(x: -geo.size.width + phase * geo.size.width * 2)
                }
                .mask(content)
            )
            .onAppear {
                withAnimation(Animation.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

private extension View {
    func shimmering() -> some View {
        modifier(ShimmerModifier())
    }
}
