import SwiftUI

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
                }
            }
            .padding(.bottom, 100)
        }
        .background(Color.white)
        .onAppear { loadData() }
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
            do {
                async let banner = doubanService.fetchTop250(start: 0, count: 10)
                async let movies = doubanService.fetchHotMovies(start: 0, count: 10)
                async let tv = doubanService.fetchHotTV(start: 0, count: 10)
                async let variety = doubanService.fetchHotVariety(start: 0, count: 10)
                async let top = doubanService.fetchTop250(start: 0, count: 10)
                bannerSubjects = try await banner
                hotMovies = try await movies
                hotTV = try await tv
                hotVariety = try await variety
                top250 = try await top
            } catch {
                print("Douban API error: \(error)")
            }
            isLoading = false
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
            if let coverUrl = subject.coverImageURL, !coverUrl.isEmpty {
                AsyncImage(url: URL(string: coverUrl)) { phase in
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
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(categories, id: \.0) { item in
                    CategoryTile(icon: item.1, title: item.2, categoryType: item.0, settings: settings)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.white)
    }
}

struct CategoryTile: View {
    let icon: String
    let title: String
    let categoryType: String
    let settings: AppSettings
    
    var body: some View {
        NavigationLink(destination: CategoryDetailView(categoryType: categoryType, categoryName: title)) {
            VStack(spacing: 6) {
                Text(icon).font(.system(size: 28))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.black)
            }
            .frame(width: 80, height: 70)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.15), lineWidth: 1))
        }
    }
}

// MARK: - 横向主题行
struct HorizontalSubjectRow: View {
    let subjects: [DoubanSubject]
    let settings: AppSettings
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(subjects) { subject in
                    SubjectCard(subject: subject, settings: settings)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - 主题卡片
struct SubjectCard: View {
    let subject: DoubanSubject
    let settings: AppSettings
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // 封面图
                if let coverUrl = subject.coverImageURL, let url = URL(string: coverUrl), !coverUrl.isEmpty {
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
                .foregroundColor(.black)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
        }
        .onTapGesture {
            settings.triggerSearch(subject.title)
        }
    }
}
