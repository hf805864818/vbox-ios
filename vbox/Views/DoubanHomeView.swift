import SwiftUI
import UIKit

// MARK: - 豆瓣首页视图
struct DoubanHomeView: View {
    @StateObject private var doubanService = DoubanService.shared
    @EnvironmentObject private var settings: AppSettings
    @State private var isLoading = true
    @State private var bannerSubjects: [DoubanSubject] = []
    @State private var hotMovies: [DoubanSubject] = []
    @State private var hotTV: [DoubanSubject] = []
    @State private var hotVariety: [DoubanSubject] = []
    @State private var top250: [DoubanSubject] = []
    @State private var showingMovies: [DoubanSubject] = []
    @State private var hotGaiaMovies: [DoubanSubject] = []
    @State private var americanTV: [DoubanSubject] = []
    @State private var currentIndex = 0
    let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 0) {
                if isLoading {
                    VStack(spacing: 20) {
                        ProgressView().scaleEffect(1.5).padding(.top, 100)
                    }
                } else {
                    if !bannerSubjects.isEmpty {
                        BannerCarousel(subjects: bannerSubjects, currentIndex: $currentIndex, settings: settings)
                    }
                    CategoryTilesView(settings: settings)
                    if !hotMovies.isEmpty {
                        SectionHeader(title: "热门电影", icon: "flame.fill")
                        HorizontalSubjectRow(subjects: hotMovies, settings: settings)
                    }
                    if !top250.isEmpty {
                        SectionHeader(title: "TOP250", icon: "crown.fill")
                        HorizontalSubjectRow(subjects: top250, settings: settings)
                    }
                    if !hotTV.isEmpty {
                        SectionHeader(title: "热门剧集", icon: "tv.fill")
                        HorizontalSubjectRow(subjects: hotTV, settings: settings)
                    }
                    if !hotVariety.isEmpty {
                        SectionHeader(title: "热门综艺", icon: "theatermasks.fill")
                        HorizontalSubjectRow(subjects: hotVariety, settings: settings)
                    }
                    if !showingMovies.isEmpty {
                        SectionHeader(title: "影院热映", icon: "film.fill")
                        HorizontalSubjectRow(subjects: showingMovies, settings: settings)
                    }
                    if !hotGaiaMovies.isEmpty {
                        SectionHeader(title: "豆瓣热门", icon: "flame.fill")
                        HorizontalSubjectRow(subjects: hotGaiaMovies, settings: settings)
                    }
                    if !americanTV.isEmpty {
                        SectionHeader(title: "值得看的英美剧", icon: "globe")
                        HorizontalSubjectRow(subjects: americanTV, settings: settings)
                    }
                }
            }
            .padding(.bottom, 100)
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .onAppear { Task { await loadData() } }
        .onReceive(timer) { _ in
            guard !bannerSubjects.isEmpty else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                currentIndex = (currentIndex + 1) % min(10, bannerSubjects.count)
            }
        }
    }
    
    private func loadData() {
        isLoading = true
        Task {
            // 独立加载每个分类，一个失败不影响其他
            async let banner = fetchSafely { try await doubanService.fetchTop250(start: 0, count: 10) }
            async let movies = fetchSafely { try await doubanService.fetchHotMovies(start: 0, count: 10) }
            async let tv = fetchSafely { try await doubanService.fetchHotTV(start: 0, count: 10) }
            async let variety = fetchSafely { try await doubanService.fetchHotVariety(start: 0, count: 10) }
            async let top = fetchSafely { try await doubanService.fetchTop250(start: 0, count: 10) }
            async let showing = fetchSafely { try await doubanService.fetchUpcomingCN(start: 0, count: 10) }
            async let hotGaia = fetchSafely { try await doubanService.fetchHotGaia(start: 0, count: 10) }
            async let american = fetchSafely { try await doubanService.fetchAmericanTV(start: 0, count: 10) }

            bannerSubjects = await banner
            hotMovies = await movies
            hotTV = await tv
            hotVariety = await variety
            top250 = await top
            showingMovies = await showing
            hotGaiaMovies = await hotGaia
            americanTV = await american

            isLoading = false
        }
    }

    private func fetchSafely(_ operation: @escaping () async throws -> [DoubanSubject]) async -> [DoubanSubject] {
        do {
            return try await operation()
        } catch {
            print("[DoubanHome] 加载失败: \(error)")
            return []
        }
    }
}

// MARK: - Banner轮播
struct BannerCarousel: View {
    let subjects: [DoubanSubject]
    @Binding var currentIndex: Int
    let settings: AppSettings
    @State private var dragOffset: CGFloat = 0
    @State private var autoPlayTimer: Timer?
    
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let cardWidth = geo.size.width * 0.75
                let cardHeight: CGFloat = 200
                let spacing: CGFloat = 12
                let sideScale: CGFloat = 0.85
                let sideOpacity: CGFloat = 0.5
                
                ZStack {
                    ForEach(0..<min(10, subjects.count), id: \.self) { index in
                        let offset = CGFloat(index - currentIndex)
                        let isCurrent = index == currentIndex
                        let scale = isCurrent ? 1.0 : sideScale
                        let opacity = isCurrent ? 1.0 : sideOpacity
                        let xOffset = offset * (cardWidth + spacing) + dragOffset
                        let zIndex = isCurrent ? 1.0 : 0.0
                        
                        BannerCard3D(subject: subjects[index], settings: settings, cardWidth: cardWidth, cardHeight: cardHeight)
                            .scaleEffect(scale)
                            .opacity(opacity)
                            .offset(x: xOffset)
                            .zIndex(zIndex)
                            .animation(.easeOut(duration: 0.35), value: currentIndex)
                            .animation(.easeOut(duration: 0.2), value: dragOffset)
                    }
                }
                .frame(width: geo.size.width, height: cardHeight)
                .contentShape(Rectangle())
                .onAppear { startAutoPlay() }
                .onDisappear { stopAutoPlay() }
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            stopAutoPlay()
                            dragOffset = value.translation.width
                        }
                        .onEnded { value in
                            let threshold: CGFloat = 50
                            if value.translation.width < -threshold {
                                withAnimation(.easeOut(duration: 0.35)) {
                                    currentIndex = min(currentIndex + 1, min(10, subjects.count) - 1)
                                }
                            } else if value.translation.width > threshold {
                                withAnimation(.easeOut(duration: 0.35)) {
                                    currentIndex = max(currentIndex - 1, 0)
                                }
                            }
                            dragOffset = 0
                            startAutoPlay()
                        }
                )
            }
            .frame(height: 200)
            
            HStack(spacing: 8) {
                ForEach(0..<min(10, subjects.count), id: \.self) { index in
                    Circle()
                        .fill(currentIndex == index ? Color(hex: "E11D48") : Color.gray.opacity(0.3))
                        .frame(width: currentIndex == index ? 8 : 6, height: currentIndex == index ? 8 : 6)
                }
            }
            .padding(.vertical, 8)
        }
    }
    
    private func startAutoPlay() {
        stopAutoPlay()
        autoPlayTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            withAnimation(.easeOut(duration: 0.35)) {
                if currentIndex < min(10, subjects.count) - 1 {
                    currentIndex += 1
                } else {
                    currentIndex = 0
                }
            }
        }
    }
    
    private func stopAutoPlay() {
        autoPlayTimer?.invalidate()
        autoPlayTimer = nil
    }
}

// MARK: - Banner卡片(3D轮播版)
struct BannerCard3D: View {
    let subject: DoubanSubject
    let settings: AppSettings
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 封面图
            if let url = DoubanImageProxyServer.shared.proxiedURL(for: subject.coverImageURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure(let error):
                        // 加载失败显示占位图
                        ZStack {
                            Rectangle().fill(Color.gray.opacity(0.2))
                            VStack(spacing: 8) {
                                Image(systemName: "photo")
                                    .font(.system(size: 40))
                                    .foregroundColor(.gray)
                                Text("加载失败")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                            }
                        }
                    case .empty:
                        // 加载中
                        ZStack {
                            Rectangle().fill(Color.gray.opacity(0.1))
                            ProgressView()
                                .scaleEffect(1.2)
                                .tint(.gray)
                        }
                    @unknown default:
                        Rectangle().fill(Color.gray.opacity(0.1))
                    }
                }
            } else {
                // 没有URL时显示占位图
                ZStack {
                    Rectangle().fill(Color.gray.opacity(0.15))
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("暂无封面")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                }
            }
            
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.5), Color.black.opacity(0.85)],
                startPoint: .top, endPoint: .bottom
            )
            
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(subject.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                    if subject.ratingValue > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", subject.ratingValue))
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.yellow)
                        }
                    }
                }
                if let year = subject.year {
                    Text(year)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .padding(12)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
        .onTapGesture {
            settings.triggerSearch(subject.title)
        }
    }
}



// MARK: - 分类磁贴
struct CategoryTilesView: View {
    let settings: AppSettings
    let categories = [
        ("movie", "🎬", "电影"), ("tv", "📺", "剧集"), ("variety", "🎭", "综艺"),
        ("top250", "🏆", "榜单"), ("animation", "🎨", "动漫"), ("hot", "🔥", "热门")
    ]
    @State private var selectedCategory: CategorySheetItem?

    struct CategorySheetItem: Identifiable {
        let id = UUID()
        let type: String
        let name: String
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(categories, id: \.0) { item in
                    CategoryTile(icon: item.1, title: item.2, settings: settings) {
                        selectedCategory = CategorySheetItem(type: item.0, name: item.2)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(settings.usesVisualSkin ? Color.clear : Color(uiColor: .systemBackground))
        .sheet(item: $selectedCategory) { category in
            CategoryDetailView(categoryType: category.type, categoryName: category.name)
                .environmentObject(settings)
        }
    }
}

struct CategoryTile: View {
    let icon: String
    let title: String
    let settings: AppSettings
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                Text(icon).font(.system(size: 28))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
            }
            .frame(width: 80, height: 70)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(tileBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(settings.usesVisualSkin ? Color.white.opacity(0.2) : Color.gray.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var tileBackground: Color {
        if settings.usesLiquidSkin { return Color.black.opacity(0.30) }
        if settings.usesFrostedSkin { return Color(uiColor: .secondarySystemGroupedBackground).opacity(0.62) }
        return Color.gray.opacity(0.08)
    }
}

// MARK: - 横向主题行
struct HorizontalSubjectRow: View {
    let subjects: [DoubanSubject]
    let settings: AppSettings
    
    @State private var lastHapticStep: Int = -1
    private let cardWidth: CGFloat = 120
    private let cardSpacing: CGFloat = 12
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: cardSpacing) {
                ForEach(Array(subjects.enumerated()), id: \.element.id) { index, subject in
                    SubjectCard(
                        subject: subject,
                        settings: settings,
                        fallDelay: Double(index) * 0.08
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let step = cardWidth + cardSpacing
                    let currentStep = Int(abs(value.translation.width) / step)
                    if currentStep != lastHapticStep {
                        lastHapticStep = currentStep
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
        )
    }
}

// MARK: - 主题卡片
struct SubjectCard: View {
    let subject: DoubanSubject
    let settings: AppSettings
    let fallDelay: Double
    
    @State private var hasAppeared = false
    private let fallDistance: CGFloat = 40
    
    var body: some View {
        // GeometryReader 放在卡片内部：每张卡片自己实时感知全局位置
        // 滚动时 SwiftUI 会重新求值，scaleEffect 跟随滚动实时变化
        GeometryReader { geo in
            let cardMidX = geo.frame(in: .global).midX
            let screenMidX = UIScreen.main.bounds.width / 2
            let distance = abs(cardMidX - screenMidX)
            let maxDistance: CGFloat = 120
            let normalized = min(distance / maxDistance, 1.0)
            // 居中卡片 scale 1.0，边缘卡片 scale 0.85
            let zoomScale = 1.0 - normalized * 0.15
            // 居中卡片 opacity 1.0，边缘卡片 opacity 0.6
            let zoomOpacity = 1.0 - Double(normalized) * 0.4
            
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    // 封面图
                    if let url = DoubanImageProxyServer.shared.proxiedURL(for: subject.coverImageURL) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 120, height: 160)
                            case .failure(_):
                                ZStack {
                                    Rectangle().fill(Color.gray.opacity(0.15))
                                    Image(systemName: "photo")
                                        .font(.system(size: 30))
                                        .foregroundColor(.gray)
                                }
                                .frame(width: 120, height: 160)
                            case .empty:
                                ZStack {
                                    Rectangle().fill(Color.gray.opacity(0.08))
                                    ProgressView()
                                        .scaleEffect(0.8)
                                        .tint(.gray)
                                }
                                .frame(width: 120, height: 160)
                            @unknown default:
                                Rectangle().fill(Color.gray.opacity(0.1))
                                    .frame(width: 120, height: 160)
                            }
                        }
                    } else {
                        ZStack {
                            Rectangle().fill(Color.gray.opacity(0.1))
                            VStack(spacing: 4) {
                                Image(systemName: "photo")
                                    .font(.system(size: 30))
                                    .foregroundColor(.gray)
                                Text("暂无封面")
                                    .font(.system(size: 10))
                                    .foregroundColor(.gray)
                            }
                        }
                        .frame(width: 120, height: 160)
                    }
                    
                    if subject.ratingValue > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", subject.ratingValue))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.yellow)
                        }
                        .padding(4)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(4)
                        .padding(4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                
                Text(subject.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
            }
            // 中心放大：跟随滚动实时变化（不加 animation，确保跟手）
            .scaleEffect(zoomScale)
            // 坠落入场：首次出现时从上方坠落
            .opacity(hasAppeared ? zoomOpacity : 0)
            .offset(y: hasAppeared ? 0 : -fallDistance)
            // spring 动画只绑定 hasAppeared，不影响滚动时的 scaleEffect
            .animation(.spring(response: 0.6, dampingFraction: 0.68), value: hasAppeared)
            .onTapGesture {
                settings.triggerSearch(subject.title)
            }
        }
        // GeometryReader 需要固定尺寸，和卡片内容一致
        .frame(width: 120, height: 210, alignment: .topLeading)
        .onAppear {
            guard !hasAppeared else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + fallDelay) {
                hasAppeared = true
            }
        }
    }
}
